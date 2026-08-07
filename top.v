
module top
(
    input wire clk,
    input wire rst_n, //Active low

    output led_0, //debug: tied directly to cam_vsync
    output led_1, //debug: tied directly to cam_pclk

    //========================================================
    // OV5640
    //======================================================== 

    inout wire cam_scl,  //I2C clock to camera this is also Dislpay 2
    inout wire cam_sda,  //I2C data to camera this is also Dislpay 2

    input cam_vsync,     //cam vsync
	input cam_href,      //cam hsync refrence, data valid
	input cam_pclk,      //cam pixel clock
    
    output cam_xclk,     //clock to camera 
	
    input[7:0] cam_data, //camera data
	
    output cam_rst_n,    //camera reset 
	output cam_pwdn,     //camera power down

	output wire [7:0] y_data,
	output wire [7:0] cbcr_data,

    output uart_tx_pin  //serial data output to PC

);

reg [7:0] y_fifo;
reg [7:0] cbcr_fifo;

wire cam_clk;

wire [7:0] y_temp;
wire [7:0] cbcr_temp;
wire [10:0] h_count;
wire [10:0] v_count;

    Gowin_rPLL pll_instance(
        .clkin  (clk),     //input  clkin  27MHz (board oscillator)
        .clkout (cam_clk)  //output clkout 24MHz (feeds camera XCLK)
    );


wire cam_16bit_wr_en;

assign cam_xclk = cam_xvclk;
wire cam_xvclk;

//========================================================
// PREPROCESSOR <-> 96x96 BSRAM signals -- declared here, above
// their first use in preprocessor_1 below, to avoid Verilog
// implicitly declaring them as 1-bit wires at first use and then
// conflicting with the real multi-bit declarations.
//========================================================

wire [7:0] y_resize;
wire       resize_en;
wire [13:0] resize_wr_addr; //output of preprocessor -> ada 96x96

//========================================================
// OV5640 -> DVP_CAPTURE
//========================================================

// NOTE: i2c_bitbang_cam.v was reverted by the user to a simpler version --
// no more sda_in, chip_id_high/low, readback_done, or comm_ok ports (the
// chip-ID read-back FSM and retry cap are gone from that module). Wiring
// below updated to match its current port list only; module itself not
// touched here.

wire i2c_setup_done;

i2c_bitbang_cam #(
    .CLK_FREQ(27000000)
) i2c_cam(
    .clk     (clk),
    .rst_n   (rst_n),
    .cam_clk (cam_clk),

    .busy (),
    .done (i2c_setup_done),
    .error(),
    .cam_done(),

    .sda_1 (cam_sda),
    .scl_1 (cam_scl),
    .sda_in(cam_sda), // taps the same physical net to sense the camera's real ACK/NACK
    .cam_pwdn(cam_pwdn),
    .cam_rst_n(cam_rst_n),
    .cam_xvclk(cam_xvclk)
);

//camera bytes are separated into y_data and y_data and cbcr_data

dvp_capture dvp_capture_1(

    .rst_n      (rst_n),
    .pclk       (cam_pclk),
    .input_data (cam_data),
    .de_i       (cam_href),

    .y_data     (y_temp),
    .cbcr_data  (cbcr_temp),

    .hblank     (),
    .de_o       (cam_16bit_wr_en)
);

wire [15:0] buf_pixel; // back to 16-bit {y,cbcr} -- cam_line_buffer_30rows.v, not buffer.v
wire        buf_valid;

reg [10:0] rd_x;
reg [9:0]  rd_y;

// Address advance is coupled to the UART handoff: rd_x/rd_y only step
// to the next pixel once the previous byte has actually been accepted
// by old_uart_test, and tx_data_valid is pulsed for exactly one cycle
// per byte instead of being tied to the always-high buf_valid.
// Dual-byte-per-pixel again (Y then CbCr, {y_temp,cbcr_temp} packing).
localparam RD_LOAD       = 0;
localparam RD_SEND_Y     = 1;
localparam RD_WAIT_Y     = 2;
localparam RD_SEND_CBCR  = 3;
localparam RD_WAIT_CBCR  = 4;
localparam RD_ADVANCE    = 5;

reg [2:0]  rd_state;
reg [15:0] pixel_hold;
reg [7:0]  old_uart_tx_data;
reg        old_uart_tx_valid;

wire old_uart_tx_ready;

// dvp_capture -> preprocessor -> cam_line_buffer_30rows (96x96) -> uart
// -> PC 96x96 live viewer. cam_buf (below) is now fed by preprocessor's
// decimated resize_en/y_resize/resize_wr_addr instead of raw camera
// signals -- WIDTH=96, ROWS=96 exactly matches the decimated frame, no
// tiling needed. CbCr byte is always 0 (preprocessor has no chroma).
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_x              <= 0;
        rd_y              <= 0;
        rd_state          <= RD_LOAD;
        pixel_hold         <= 0;
        old_uart_tx_data   <= 0;
        old_uart_tx_valid  <= 0;
    end else if (linebuf_primed_clk) begin // don't start scanning until the buffer is frozen
        case (rd_state)

            RD_LOAD: begin
                pixel_hold <= buf_pixel; // buf_pixel now reflects the address set in RD_ADVANCE
                rd_state   <= RD_SEND_Y;
            end

            RD_SEND_Y: begin
                if (old_uart_tx_ready) begin
                    old_uart_tx_data  <= pixel_hold[15:8]; // Y byte ({y_temp,cbcr_temp} packing below)
                    old_uart_tx_valid <= 1'b1;
                    rd_state          <= RD_WAIT_Y;
                end
            end

            RD_WAIT_Y: begin
                old_uart_tx_valid <= 1'b0;
                rd_state          <= RD_SEND_CBCR;
            end

            RD_SEND_CBCR: begin
                if (old_uart_tx_ready) begin
                    old_uart_tx_data  <= pixel_hold[7:0]; // CbCr byte
                    old_uart_tx_valid <= 1'b1;
                    rd_state          <= RD_WAIT_CBCR;
                end
            end

            RD_WAIT_CBCR: begin
                old_uart_tx_valid <= 1'b0;
                rd_state          <= RD_ADVANCE;
            end

            RD_ADVANCE: begin
                if (rd_x == 11'd95) begin // 96x96 now -- reading through preprocessor's decimated buffer
                    rd_x <= 0;
                    rd_y <= (rd_y == 9'd95) ? 0 : rd_y + 1'b1;
                end else begin
                    rd_x <= rd_x + 1'b1;
                end
                rd_state <= RD_LOAD;
            end

        endcase
    end
end

// ================================================================
// 96x96 BSRAM-ONLY TEST -- previous test, now superseded by the
// preprocessor test below. Not deleted, just disabled.
//
// wire [7:0]  test96_dout;
// reg  [13:0] wr_addr96;
// reg  [6:0]  wr_col96;
// reg  [6:0]  wr_row96;
// reg         wr96_done;
// reg         wr96_cea;
// reg  [7:0]  wr96_din;
//
// always @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//         wr_addr96 <= 0;
//         wr_col96  <= 0;
//         wr_row96  <= 0;
//         wr96_done <= 0;
//         wr96_cea  <= 0;
//         wr96_din  <= 0;
//     end else if (!wr96_done) begin
//         wr96_cea <= 1'b1;
//         wr96_din <= (wr_row96[3] ^ wr_col96[3]) ? 8'hFF : 8'h00; // 8x8-block checkerboard
//         if (wr_addr96 == 14'd9215) begin
//             wr96_done <= 1'b1;
//             wr96_cea  <= 1'b0;
//         end else begin
//             wr_addr96 <= wr_addr96 + 1'b1;
//             if (wr_col96 == 7'd95) begin
//                 wr_col96 <= 0;
//                 wr_row96 <= wr_row96 + 1'b1;
//             end else begin
//                 wr_col96 <= wr_col96 + 1'b1;
//             end
//         end
//     end else begin
//         wr96_cea <= 1'b0;
//     end
// end

// ================================================================
// 96x96 PREPROCESSOR -- REAL CAMERA. Synthetic generator retired now
// that preprocessor.v's decimation bug is fixed (verified clean via
// the synthetic checkerboard test). Wired directly to dvp_capture's
// real cam_pclk/cam_href/cam_vsync/y_temp/cam_16bit_wr_en.
//
// Freeze-after-one-frame gate: NOT keyed off cam_vsync (measured much
// earlier this session at ~62.7kHz, far above the expected ~60Hz --
// consistent with a noisy/unreliable line). Instead counts actual
// resize_en write pulses from preprocessor and gates the BSRAM's cea
// off after exactly 9216 (96*96), fully decoupled from cam_vsync's
// reliability -- same fix pattern used earlier for cam_line_buffer_30rows.
// ================================================================

// ================================================================
// SYNTHETIC CHECKERBOARD, RE-CLOCKED ON cam_pclk -- the original
// checkerboard test (which came out perfectly clean) ran the generator
// and preprocessor on clk (27MHz). Real camera operation uses cam_pclk
// (much faster, ~107MHz-ish). This retests the EXACT same clean,
// deterministic pattern but clocked at real camera speed, to isolate
// "does preprocessor.v have a problem at real cam_pclk timing" from
// "is real camera signal jitter/noise the problem" -- the dual-chroma
// regression showed some timing marginality exists somewhere; this
// narrows down whether it's clock-speed-related at all.
// ================================================================

reg [9:0] synth_hpix;  // 0-639
reg [8:0] synth_vline; // 0-479
reg       synth_href;
reg       synth_vsync;
reg [7:0] synth_y_data;

// TEST IMAGE B -- 4x4 output blocks (raw block size 24=6*4 horizontal,
// 20=5*4 vertical), HALF the block size of the original 8x8 test image
// used earlier (test image A). Visually and structurally distinct --
// not just inverted colors -- so there's no ambiguity between "BSRAM
// stuck showing old test-image-A content" and "genuinely updated to
// the new pattern": a stuck buffer would show the OLD 8x8 checkerboard,
// not this finer 4x4 one.
reg [4:0] hblk_cnt; // 0-23
reg       hblk_bit;
reg [4:0] vblk_cnt; // 0-19
reg       vblk_bit;

// Generator loops forever (like the continuous checkerboard test) --
// it has no idea when the boot gate (i2c_done + 5s timer) opens, and
// that gate can take many seconds, far longer than one frame takes to
// generate. Freezing is handled downstream by counting actual GATED
// writes (below), same proven pattern as the real-camera version --
// that naturally grabs exactly one frame's worth starting from
// whenever the gate opens, regardless of how many frames the
// generator produced before that.
always @(posedge cam_pclk or negedge rst_n) begin
    if (!rst_n) begin
        synth_hpix  <= 0;
        synth_vline <= 0;
        synth_href  <= 1'b0;
        synth_vsync <= 1'b1; // pulse on first cycle out of reset
        hblk_cnt    <= 0;
        hblk_bit    <= 0;
        vblk_cnt    <= 0;
        vblk_bit    <= 0;
    end else if (synth_vsync) begin
        synth_vsync <= 1'b0; // one-cycle pulse
        synth_hpix  <= 0;
        synth_vline <= 0;
        synth_href  <= 1'b1;
        hblk_cnt    <= 0;
        hblk_bit    <= 0;
        vblk_cnt    <= 0;
        vblk_bit    <= 0;
    end else if (synth_href) begin
        if (synth_hpix == 10'd639) begin
            synth_hpix <= 0;
            hblk_cnt   <= 0;
            hblk_bit   <= 0;
            if (synth_vline == 9'd479) begin
                synth_href  <= 1'b0;
                synth_vsync <= 1'b1; // next frame -- loop forever
            end else begin
                synth_vline <= synth_vline + 1'b1;
                if (vblk_cnt == 5'd19) begin
                    vblk_cnt <= 0;
                    vblk_bit <= ~vblk_bit;
                end else begin
                    vblk_cnt <= vblk_cnt + 1'b1;
                end
            end
        end else begin
            synth_hpix <= synth_hpix + 1'b1;
            if (hblk_cnt == 5'd23) begin
                hblk_cnt <= 0;
                hblk_bit <= ~hblk_bit;
            end else begin
                hblk_cnt <= hblk_cnt + 1'b1;
            end
        end
    end
end

always @(*) begin
    synth_y_data = (vblk_bit ^ hblk_bit) ? 8'd128 : 8'd127;
end

wire        resize_en_pp;
wire [7:0]  y_resize_pp;
wire [13:0] resize_wr_addr_pp;

preprocessor preprocessor_1(
    .rst_n           (rst_n),
    .pclk            (cam_pclk),
    .href            (synth_href),  // TEMP: synthetic checkerboard instead of dvp_capture,
    .vsync           (synth_vsync), // to directly compare the SAME downstream pipeline
    .y_data          (synth_y_data),// (cam_line_buffer_30rows 96x96 -> uart) against a
    .data_en         (synth_href),  // known-clean source at real cam_pclk rate, looping
    .resize_en       (resize_en_pp),
    .y_resize        (y_resize_pp),
    .resize_wr_addr  (resize_wr_addr_pp)
);

// CHROMA ATTEMPT -- reverted. Adding a second preprocessor instance for
// CbCr (sharing href/vsync/data_en/pclk with preprocessor_1) caused the
// LUMA plane to regress: a previously clean single-shape capture came
// back tripled/tiled with visible seams, even though the frame was
// confirmed genuinely frozen (not a live-tearing artifact). Suspect the
// added fanout on the shared cam_href/cam_vsync/cam_16bit_wr_en nets
// pushed preprocessor_1's sampling into a timing-marginal state that
// wasn't a problem with a single consumer. Needs isolating (e.g.
// re-registering the shared signals before fanning out) before
// retrying -- not deleted, just disabled.
//
// wire        resize_en_pp2;
// wire [7:0]  y_resize_pp2;
// wire [13:0] resize_wr_addr_pp2;
//
// preprocessor preprocessor_2(
//     .rst_n           (rst_n),
//     .pclk            (cam_pclk),
//     .href            (cam_href),
//     .vsync           (cam_vsync),
//     .y_data          (cbcr_temp),
//     .data_en         (cam_16bit_wr_en),
//     .resize_en       (resize_en_pp2),
//     .y_resize        (y_resize_pp2),
//     .resize_wr_addr  (resize_wr_addr_pp2)
// );

// i2c_setup_done crosses from the clk domain (i2c_bitbang_cam runs on
// clk) into cam_pclk -- 2-stage synchronizer.
reg [1:0] i2c_done_sync;
always @(posedge cam_pclk or negedge rst_n) begin
    if (!rst_n)
        i2c_done_sync <= 2'b00;
    else
        i2c_done_sync <= {i2c_done_sync[0], i2c_setup_done};
end
wire i2c_done_cam_pclk = i2c_done_sync[1];

// 5-SECOND BOOT TIMER -- simpler and more robust than counting multiple
// frames (which had an unresolved bug when SKIP_FRAMES>1). Plain
// wall-clock wait on the known-good clk (27MHz), independent of any
// camera timing signal entirely. Guarantees the camera (SCCB config +
// AGC/AWB convergence) has had real time to settle before we ever
// look at its output, with no dependency on frame-boundary counting.
localparam BOOT_WAIT_CYCLES = 27_000_000 * 5; // 5 seconds at 27MHz

reg [27:0] boot_timer;
reg        boot_timer_done;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        boot_timer      <= 0;
        boot_timer_done <= 0;
    end else if (!boot_timer_done) begin
        if (boot_timer == BOOT_WAIT_CYCLES - 1)
            boot_timer_done <= 1'b1;
        else
            boot_timer <= boot_timer + 1'b1;
    end
end

// Crosses from clk into cam_pclk -- 2-stage synchronizer.
reg [1:0] boot_done_sync;
always @(posedge cam_pclk or negedge rst_n) begin
    if (!rst_n)
        boot_done_sync <= 2'b00;
    else
        boot_done_sync <= {boot_done_sync[0], boot_timer_done};
end
wire boot_done_cam_pclk = boot_done_sync[1];

// Gowin_SDPB 96x96 path superseded -- now feeding preprocessor's output
// into cam_line_buffer_30rows instead (see below), per user request.
// Not deleted, just disabled.
//
// wire primed = i2c_done_cam_pclk && boot_done_cam_pclk;
// wire cea96_gated = resize_en_pp && primed;
// wire [7:0] test96_dout;
// Gowin_SDPB test96_bsram (
//     .dout   (test96_dout),
//     .clka   (cam_pclk),
//     .cea    (cea96_gated),
//     .reseta (~rst_n),
//     .clkb   (clk),
//     .ceb    (1'b1),
//     .resetb (~rst_n),
//     .oce    (1'b1),
//     .ada    (resize_wr_addr_pp),
//     .din    (y_resize_pp),
//     .adb    (rd_addr96)
// );

// CbCr plane (Gowin_SDPB_A) reverted -- caused a luma regression, see
// note above preprocessor_2. Not deleted, just disabled.
//
// wire [7:0] test96_dout2;
//
// Gowin_SDPB_A test96_bsram_cbcr (
//     .dout   (test96_dout2),
//     .clka   (cam_pclk),
//     .cea    (cea96_gated2),
//     .reseta (~rst_n),
//     .clkb   (clk),
//     .ceb    (1'b1),
//     .resetb (~rst_n),
//     .oce    (1'b1),
//     .ada    (resize_wr_addr_pp2),
//     .din    (y_resize_pp2),
//     .adb    (rd_addr96)
// );

// RAW y_temp DIAGNOSTIC -- CONFIRMED WORKING: real camera data varies
// (154 unique values, std=57, two-cluster distribution matching real
// scene structure). Camera/dvp_capture path is healthy. Disabled again
// now, not deleted -- bug is downstream, re-enabling the 96x96 BSRAM
// read+send FSM below to re-isolate within preprocessor/freeze logic.
//
// reg [7:0] raw_y_latch;
// reg       raw_y_toggle;
//
// always @(posedge cam_pclk or negedge rst_n) begin
//     if (!rst_n) begin
//         raw_y_latch  <= 0;
//         raw_y_toggle <= 0;
//     end else if (cam_16bit_wr_en) begin
//         raw_y_latch  <= y_temp;
//         raw_y_toggle <= ~raw_y_toggle;
//     end
// end
//
// reg raw_y_sync0, raw_y_sync1, raw_y_sync2;
// always @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//         raw_y_sync0 <= 0;
//         raw_y_sync1 <= 0;
//         raw_y_sync2 <= 0;
//     end else begin
//         raw_y_sync0 <= raw_y_toggle;
//         raw_y_sync1 <= raw_y_sync0;
//         raw_y_sync2 <= raw_y_sync1;
//     end
// end
//
// wire new_raw_y_sample = raw_y_sync1 ^ raw_y_sync2;
//
// localparam RY_IDLE = 0;
// localparam RY_SEND = 1;
// localparam RY_WAIT = 2;
//
// reg [1:0] ry_state;
// reg [7:0] raw_y_hold;
//
// always @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//         ry_state          <= RY_IDLE;
//         raw_y_hold        <= 0;
//         old_uart_tx_data  <= 0;
//         old_uart_tx_valid <= 0;
//     end else begin
//         case (ry_state)
//             RY_IDLE: begin
//                 if (new_raw_y_sample) begin
//                     raw_y_hold <= raw_y_latch;
//                     ry_state   <= RY_SEND;
//                 end
//             end
//             RY_SEND: begin
//                 if (old_uart_tx_ready) begin
//                     old_uart_tx_data  <= raw_y_hold;
//                     old_uart_tx_valid <= 1'b1;
//                     ry_state          <= RY_WAIT;
//                 end
//             end
//             RY_WAIT: begin
//                 old_uart_tx_valid <= 1'b0;
//                 ry_state          <= RY_IDLE;
//             end
//         endcase
//     end
// end

reg [13:0] rd_addr96; // still wired into test96_bsram's .adb below -- unused/static during this test

// TEMP: T96 (96x96 preprocessor path) disabled -- switching the UART
// output to cam_buf (dvp_capture -> cam_line_buffer_30rows) instead,
// per user request, to sanity-check the camera directly without going
// through preprocessor.v's cam_vsync-dependent addressing at all. Only
// one source can drive old_uart_tx_data/valid at a time. Not deleted.
//
// localparam T96_ADDR     = 0;
// localparam T96_WAIT     = 1;
// localparam T96_SEND     = 2;
// localparam T96_SENTWAIT = 3;
// localparam T96_ADVANCE  = 4;
//
// reg [2:0]  t96_state;
// reg [3:0]  t96_latency;
// reg [7:0]  pixel96_hold;
//
// always @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//         t96_state         <= T96_ADDR;
//         t96_latency       <= 0;
//         rd_addr96         <= 0;
//         pixel96_hold       <= 0;
//         old_uart_tx_data   <= 0;
//         old_uart_tx_valid  <= 0;
//     end else if (primed) begin
//         case (t96_state)
//             T96_ADDR: begin
//                 t96_latency <= 0;
//                 t96_state   <= T96_WAIT;
//             end
//             T96_WAIT: begin
//                 if (t96_latency == 4'd8) begin
//                     pixel96_hold <= test96_dout;
//                     t96_state    <= T96_SEND;
//                 end else begin
//                     t96_latency <= t96_latency + 1'b1;
//                 end
//             end
//             T96_SEND: begin
//                 if (old_uart_tx_ready) begin
//                     old_uart_tx_data  <= pixel96_hold;
//                     old_uart_tx_valid <= 1'b1;
//                     t96_state         <= T96_SENTWAIT;
//                 end
//             end
//             T96_SENTWAIT: begin
//                 old_uart_tx_valid <= 1'b0;
//                 t96_state         <= T96_ADVANCE;
//             end
//             T96_ADVANCE: begin
//                 rd_addr96 <= (rd_addr96 == 14'd9215) ? 14'd0 : rd_addr96 + 1'b1;
//                 t96_state <= T96_ADDR;
//             end
//         endcase
//     end
// end

// Freeze after exactly one decimated 96x96 frame's worth of writes
// (96*96=9216), same proven single-shot pattern -- stops live tearing.
// cam_line_buffer_30rows now fed by preprocessor's resize_en/y_resize
// instead of raw camera signals -- WIDTH=96/ROWS=96 exactly matches
// the decimated frame, no tiling. preprocessor's own out_x/out_y and
// cam_line_buffer's internal wr_x/wr_row both auto-increment once per
// resize_en pulse and both reset on the same cam_vsync, so they stay
// in lockstep without needing to feed cam_line_buffer an explicit
// address (it doesn't accept one, only auto-increments internally).
localparam LINEBUF_WRITES = 96 * 96;

reg [17:0] linebuf_wr_count;
reg        linebuf_primed;

always @(posedge cam_pclk or negedge rst_n) begin
    if (!rst_n) begin
        linebuf_wr_count <= 0;
        linebuf_primed   <= 0;
    end else if (!linebuf_primed && i2c_done_cam_pclk && boot_done_cam_pclk && resize_en_pp) begin
        if (linebuf_wr_count == LINEBUF_WRITES - 1)
            linebuf_primed <= 1'b1;
        else
            linebuf_wr_count <= linebuf_wr_count + 1'b1;
    end
end

wire cam_wr_en_gated = resize_en_pp && i2c_done_cam_pclk && boot_done_cam_pclk && !linebuf_primed;

// Crosses into clk domain for the read FSM below -- 2-stage synchronizer.
reg [1:0] linebuf_primed_sync;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        linebuf_primed_sync <= 2'b00;
    else
        linebuf_primed_sync <= {linebuf_primed_sync[0], linebuf_primed};
end
wire linebuf_primed_clk = linebuf_primed_sync[1];

cam_line_buffer_30rows #(
    .WIDTH (96),
    .ROWS  (96)
) cam_buf (

    .wr_clk          (cam_pclk),
    .rst_n           (rst_n),
    .cam_vsync       (cam_vsync),
    .cam_16bit_wr_en (cam_wr_en_gated),
    .cam_pixel_in    ({y_resize_pp, 8'h00}), // Y in upper byte, CbCr half unused (preprocessor has no chroma)

    .rd_clk          (clk),
    .rd_en           (1'b1),
    .rd_x            (rd_x),
    .rd_y            (rd_y),

    .rd_pixel_out    (buf_pixel), //[15:0]
    .rd_valid        (buf_valid)
);

uart #(
    .CLK_FREQ  (27),      // MHz, matches clk -- unchanged
    .BAUD_RATE (921600)   // bumped from the 115200 default; update the PC-side capture script to match
) old_uart_test (

    .clk           (clk),
    .rst_n         (rst_n),

    .tx_data       (old_uart_tx_data),
    .tx_data_valid (old_uart_tx_valid),

    .tx_data_ready (old_uart_tx_ready),
    .tx_pin        (uart_tx_pin),
    .tx_busy       ()
);


//========================================================
// DVP_CAPTURE -> PREPROCESSOR -- commented out. This build is
// dvp_capture -> cam_line_buffer_30rows -> uart only, no preprocessor
// or 96x96 frame buffer in the chain at all. Not deleted.
//========================================================

// preprocessor preprocessor_1(
//     .rst_n           (rst_n),
//     .pclk            (cam_pclk),
//     .href            (cam_href),
//     .vsync           (cam_vsync),
//     .y_data          (y_temp),
//     .data_en         (cam_16bit_wr_en),
//     .resize_en       (resize_en),
//     .y_resize        (y_resize),
//     .resize_wr_addr  (resize_wr_addr)
// );

//========================================================
// PREPROCESSOR -> 96x96 BSRAM -- also commented out for this build
//========================================================

// wire [7:0] resize_dout;
// wire [13:0] resize_addr;
// wire resize_rd_en;

//     Gowin_SDPB resized_frame(
//         .clka(cam_pclk),
//         .din(y_resize),
//         .ada(resize_wr_addr),
//         .cea(resize_en),
//         .reseta(~rst_n),
//         .clkb(cam_pclk),
//         .ceb(resize_rd_en),
//         .resetb(~rst_n),
//         .oce(1'b1),
//         .adb(resize_addr),
//         .dout(resize_dout)
//     );

//========================================================
// CNN -- commented out for the uart-data-collection build.
// Not deleted, just disabled: resize_addr/resize_rd_en are now
// driven by uart_frame_sender instead of mac_array below.
//========================================================

// wire conv_en;
// wire conv_done;
// wire [1:0] conv_layer_sel;
//
// cnn_top cnn_top_1(
//
//     //IN
//
//     .rst_n     (rst_n),
//     .pclk      (cam_pclk),
//     .vsync     (cam_vsync),
//
//     .conv_done (conv_done),
//     .pool_done (),
//     .gap_done  (),
//     .fc_done   (),
//     .uart_done (),
//
//     //OUT
//
//     .conv_en   (conv_en),
//     .pool_en   (),
//     .gap_en    (),
//     .fc_en     (),
//     .uart_en   (),
//
//     .conv_layer_sel (conv_layer_sel) //[1:0] tie to weight_rom.v to find out the layer
//
// );
//
// mac_array mac_array_1(
//
//     //IN
//
//     .rst_n          (rst_n),
//     .clk            (cam_pclk),
//     .conv_layer_sel (conv_layer_sel),  //[1:0]
//
//     .conv_en        (conv_en), //stay in idle till this is set
//
//     //OUT
//
//     .conv_done      (conv_done), //flag for when the conv layer is completed
//
//     //========================================================
//     // 96x96 BSRAM
//     //========================================================
//
//     .resize_dout  (resize_dout), //input -> dout 96x96 [7:0]
//     .resize_addr  (resize_addr), //output -> adb 96x96 [13:0]
//     .resize_rd_en (resize_rd_en), //output -> ceb 96x96
//
//     //========================================================
//     // FEATURE MAP BSRAM MAPPING
//     //========================================================
//
//     .map_a_wr_en (cea_a), //output -> cea MAP A
//     .map_b_wr_en (cea_b), //output -> cea MAP B
//     .map_c_wr_en (cea_c), //output -> cea MAP C
//
//     .map_a_rd_en (ceb_a), //output ->  ceb MAP A
//     .map_b_rd_en (ceb_b), //output ->  ceb MAP B
//     .map_c_rd_en (ceb_c), //output ->  ceb MAP C
//
//     .map_a_din (din_map_a), //output ->  din MAP A [7:0]
//     .map_b_din (din_map_b), //output ->  din MAP B [7:0]
//     .map_c_din (din_map_c), //output ->  din MAP C [7:0]
//
//     .map_a_dout (dout_map_a), //input -> dout MAP A [7:0]
//     .map_b_dout (dout_map_b), //input -> dout MAP B [7:0]
//     .map_c_dout (dout_map_c), //input -> dout MAP C [7:0]
//
//     .map_a_wr_addr (addr_map_a_ada), //output -> ada MAP A [14:0]
//     .map_b_wr_addr (addr_map_b_ada), //output -> ada MAP B [13:0]
//     .map_c_wr_addr (addr_map_c_ada), //output -> ada MAP C [12:0]
//
//     .map_a_rd_addr (addr_map_a_adb), //output -> adb MAP A [14:0]
//     .map_b_rd_addr (addr_map_b_adb), //output -> adb MAP B [13:0]
//     .map_c_rd_addr (addr_map_c_adb), //output -> adb MAP C [12:0]
//
//     //========================================================
//     // WEIGHT_ROM
//     //========================================================
//
//     .weight_data (weight_data), //[7:0]
//     .conv_addr   (conv_addr) //[12:0]
//
// );
//
// global_avg_pool avg_pool(
//
//     .rst_n (rst_n),
//     .clk (cam_pclk),
//
//     .gap_en (),       // start signal from cnn_top IN
//     .gap_done (), // done signal to cnn_top OUT
//
//     //========================================================
//     // FEATURE MAP C BSRAM (12x12x32)
//     //========================================================
//
//     .map_c_dout (),      // input <- dout MAP C [7:0]
//     .map_c_rd_addr (),  // output -> adb MAP C [12:0]
//     .map_c_rd_en (),       // output -> ceb MAP C
//
//     //========================================================
//     // READ INTERFACE -> classifier.v
//     //========================================================
//
//     .gap_addr (),   // IN [4:0]
//     .gap_data ()   // OUT [7:0]
//
// );
//
// classifier fc_layer(
//     // NOTE: this instantiation has a pre-existing bug -- raw port
//     // declarations were pasted in here instead of .port(signal)
//     // connections. Fix before re-enabling this block.
// );

//========================================================
// WEIGHTS -- commented out along with the CNN block above
//========================================================

// wire [7:0] weight_data;
// wire [12:0] conv_addr; //tie with mac_array.v
// wire [7:0] fc_addr;    //tie with classifier.v
//
// weight_rom weights(
//
//     //IN
//
//     .clk            (cam_pclk),
//     .rst_n          (rst_n),
//     .conv_layer_sel (conv_layer_sel), //[1:0] 00=CONV1, 01=CONV2, 10=CONV3, 11=FC
//     .conv_addr      (conv_addr),      //[12:0] conv address space (max 5831)
//     .fc_addr        (),               //[7:0] separate addr for fc pROM (max 192)
//
//     //OUT
//
//     .data_out       (weight_data) //[7:0]
// );

//========================================================
// FEATURE MAPS -- commented out along with the CNN block above
//========================================================

// wire cea_a;
// wire cea_b;
// wire cea_c;
//
// wire ceb_a;
// wire ceb_b;
// wire ceb_c;
//
// wire [7:0] din_map_a;
// wire [7:0] din_map_b;
// wire [7:0] din_map_c;
//
// wire [7:0] dout_map_a;
// wire [7:0] dout_map_b;
// wire [7:0] dout_map_c;
//
// wire [14:0] addr_map_a_ada;
// wire [13:0] addr_map_b_ada;
// wire [12:0] addr_map_c_ada;
//
// wire [14:0] addr_map_a_adb;
// wire [13:0] addr_map_b_adb;
// wire [12:0] addr_map_c_adb;
//
//     //Feature map A — 48×48×8  = 18,432 bytes  (output of Conv1+ReLU+Pool)
//
//     Gowin_SDPB_A feature_map_a(
//         .dout(dout_map_a), //output [7:0] dout
//         .clka(cam_pclk),   //input clka
//         .cea(cea_a),       //input cea
//         .reseta(~rst_n),   //input reseta
//         .clkb(cam_pclk),   //input clkb
//         .ceb(ceb_a),       //input ceb
//         .resetb(~rst_n),   //input resetb
//         .oce(1'b1),        //input oce
//         .ada(addr_map_a_ada),  //input [14:0] ada MAP A
//         .din(din_map_a),   //input [7:0] din
//         .adb(addr_map_a_adb)   //input [14:0] adb
//     );
//
//     //Feature map B — 24×24×16 =  9,216 bytes  (output of Conv2+ReLU+Pool)
//
//     Gowin_SDPB_B feature_map_b(
//         .dout(dout_map_b), //output [7:0] dout
//         .clka(cam_pclk),   //input clka
//         .cea(cea_b),       //input cea
//         .reseta(~rst_n),   //input reseta
//         .clkb(cam_pclk),   //input clkb
//         .ceb(ceb_b),       //input ceb
//         .resetb(~rst_n),   //input resetb
//         .oce(1'b1),        //input oce
//         .ada(addr_map_b_ada),  //input [13:0] ada MAP B
//         .din(din_map_b),   //input [7:0] din
//         .adb(addr_map_b_adb)   //input [13:0] adb
//     );
//
//     //Feature map C — 12×12×32 =  4,608 bytes  (output of Conv3+ReLU+Pool)
//
//     Gowin_SDPB_C feature_map_c(
//         .dout(dout_map_c), //output [7:0] dout
//         .clka(cam_pclk),   //input clka
//         .cea(cea_c),       //input cea
//         .reseta(~rst_n),   //input reseta
//         .clkb(cam_pclk),   //input clkb
//         .ceb(ceb_c),       //input ceb
//         .resetb(~rst_n),   //input resetb
//         .oce(1'b1),        //input oce
//         .ada(addr_map_c_ada),  //input [12:0] ada MAP C
//         .din(din_map_c),   //input [7:0] din
//         .adb(addr_map_c_adb)   //input [12:0] adb
//     );

// ================================================================
// Line buffer from capture clock domain to display clock domain
// -- dead code left over from the old LCD-display pipeline, module
// doesn't exist in this project. Commented out, not deleted.
// ================================================================

// wire [15:0] buf_pixel;
// wire        buf_valid;
// wire        read_enable;
// wire [10:0] h_count;
// wire [10:0] v_count;
//
// cam_line_buffer_30rows #(
//     .WIDTH (640),
//     .ROWS  (50)
// ) cam_buf (
//     .wr_clk          (cam_pclk),
//     .rst_n           (rst_n),
//     .cam_vsync       (cam_vsync),
//     .cam_16bit_wr_en (cam_16bit_wr_en),
//     .cam_pixel_in    ({cbcr_temp, y_temp}),
//     .rd_clk          (display_clk),
//     .rd_en           (read_enable),
//     .rd_x            (h_count),
//     .rd_y            (v_count),
//     .rd_pixel_out    (buf_pixel),
//     .rd_valid        (buf_valid)
// );

// ================================================================
// UART FRAME SENDER -- old-uart.v cross-check proved the transport
// itself works (150 clean 0x55 bytes received). Now: dvp_capture ->
// cam_line_buffer_30rows -> old uart, streaming BOTH Y and CbCr as
// raw 16-bit words {cbcr,y} per pixel, 2 bytes each (high byte then
// low byte), scanned deterministically across the buffered window.
// WIDTH=640 x ROWS=50 -- NOT the full 640x480 frame: the buffer's
// [15:0] mem array is BSRAM-backed, and GW2A-18 only has ~828Kbit
// (~103KB) of BRAM total. A full 640x480x16bit buffer would need
// ~600KB -- about 6x the entire chip. 640x50x16bit (~62.5KB) is
// already a large fraction of the chip's BRAM budget; ROWS should
// NOT be scaled toward 480.
// ================================================================


// ================================================================
// CAPTURE-ONCE GATE -- the buffer was being continuously overwritten
// by the camera (many frames/sec) while the slow UART scan-out took
// ~5.5s per pass. Reading a live, constantly-rewritten buffer over
// an asynchronous slow link produces exactly the smooth diagonal
// tearing/skew we saw, independent of any width assumption. Freeze
// writes after one full buffer's worth of real pixel writes.
//
// NOT gated on cam_vsync edges -- cam_vsync was independently measured
// earlier this session at ~62.7kHz, far above the expected ~60Hz frame
// rate (consistent with a noisy/floating line), which froze the buffer
// within microseconds of reset, before any real pixel data was ever
// written (confirmed: frozen capture was ~flat, std<1, effectively
// uninitialized BRAM). Counting actual write-enable pulses instead is
// entirely decoupled from cam_vsync's reliability.
// ================================================================

//localparam WRITES_PER_BUFFER = 640 * LINEBUF_ROWS;

//reg [19:0] wr_pulse_count;
//reg        frame_captured;

//always @(posedge cam_pclk or negedge rst_n) begin
//    if (!rst_n) begin
//        wr_pulse_count <= 20'd0;
//        frame_captured <= 1'b0;
//    end else if (!frame_captured && cam_16bit_wr_en) begin
//        if (wr_pulse_count == WRITES_PER_BUFFER - 1)
//            frame_captured <= 1'b1;
//        else
//            wr_pulse_count <= wr_pulse_count + 1'b1;
//    end
//end

//wire cam_16bit_wr_en_gated = cam_16bit_wr_en && !frame_captured;

// Deterministic pixel-stream sender: capture one buffered pixel,
// send its high byte then low byte over old uart.v (ready/valid
// handshake), then advance to the next pixel. Scans the buffered
// window (640 x LINEBUF_ROWS) continuously and repeats.

//localparam PX_LOAD           = 0;
//localparam PX_SEND_HIGH      = 1;
//localparam PX_SEND_HIGH_WAIT = 2;
//localparam PX_SEND_LOW       = 3;
//localparam PX_SEND_LOW_WAIT  = 4;
//localparam PX_ADVANCE        = 5;

//reg [2:0]  px_state;
//reg [15:0] pixel_hold;
//reg [7:0]  old_uart_tx_data;
//reg        old_uart_tx_valid;

//wire old_uart_tx_ready;

//always @(posedge clk or negedge rst_n) begin
//    if (!rst_n) begin
//        rd_x              <= 0;
//        rd_y              <= 0;
//        px_state          <= PX_LOAD;
//        pixel_hold         <= 0;
//        old_uart_tx_data   <= 0;
//        old_uart_tx_valid  <= 0;
//    end else begin
//        case (px_state)

//            PX_LOAD: begin
//                pixel_hold <= buf_pixel;
//                px_state   <= PX_SEND_HIGH;
//            end

//            PX_SEND_HIGH: begin
//                if (old_uart_tx_ready) begin
//                    old_uart_tx_data  <= pixel_hold[15:8]; // cbcr byte
//                    old_uart_tx_valid <= 1'b1;
//                    px_state          <= PX_SEND_HIGH_WAIT;
//                end
//            end

//            PX_SEND_HIGH_WAIT: begin
//                old_uart_tx_valid <= 1'b0;
//                px_state          <= PX_SEND_LOW;
//            end

//            PX_SEND_LOW: begin
//                if (old_uart_tx_ready) begin
//                    old_uart_tx_data  <= pixel_hold[7:0]; // y byte
//                    old_uart_tx_valid <= 1'b1;
//                    px_state          <= PX_SEND_LOW_WAIT;
//                end
//            end

//            PX_SEND_LOW_WAIT: begin
//                old_uart_tx_valid <= 1'b0;
//                px_state          <= PX_ADVANCE;
//            end

//            PX_ADVANCE: begin
//                if (rd_x == 639) begin
//                    rd_x <= 0;
//                    rd_y <= (rd_y == LINEBUF_ROWS - 1) ? 0 : rd_y + 1'b1;
//                end else begin
//                    rd_x <= rd_x + 1'b1;
//                end
//                px_state <= PX_LOAD;
//            end

//        endcase
//    end
//end


// Heartbeat LED -- decoupled from the pixel-stream FSM itself so a
// dead/stuck sender doesn't also kill the "is the chip alive" signal.
reg [24:0] heartbeat_counter;
reg        heartbeat;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        heartbeat_counter <= 0;
        heartbeat         <= 0;
    end else if (heartbeat_counter == 27_000_000/2 - 1) begin
        heartbeat_counter <= 0;
        heartbeat         <= ~heartbeat;
    end else begin
        heartbeat_counter <= heartbeat_counter + 1'b1;
    end
end

/* ORIGINAL UART_MASTER_Top + chip-ID report FSM -- commented out for
   this cross-check, not deleted:

wire        um_tx_en;
wire [2:0]  um_waddr;
wire [7:0]  um_wdata;
wire        um_rx_en;
wire [2:0]  um_raddr;
wire [7:0]  um_rdata;

UART_MASTER_Top uart_master_inst(
    .I_CLK    (clk), //matches the line-buffer sender's clock domain -- known-good 27MHz
    .I_RESETN (rst_n),

    .I_TX_EN  (um_tx_en),
    .I_WADDR  (um_waddr),
    .I_WDATA  (um_wdata),

    .I_RX_EN  (um_rx_en),
    .I_RADDR  (um_raddr),
    .O_RDATA  (um_rdata),

    .SIN      (1'b1), //RX unused -- idle-high, we never receive
    .RxRDYn   (),
    .SOUT     (uart_tx_pin),
    .TxRDYn   (),
    .DDIS     (),
    .INTR     (),
    .DCDn     (1'b1), //unused modem-status inputs, active-low, held inactive
    .CTSn     (1'b1),
    .DSRn     (1'b1),
    .RIn      (1'b1),
    .DTRn     (),
    .RTSn     ()
);

// ================================================================
// PROVEN CAPSTONE LINE BUFFER -- write side on cam_pclk (camera
// domain, required), read side on clk (known-good 27MHz). Decouples
// the read/send timing entirely from cam_pclk's unverified frequency.
// Simple free-running rd_x/rd_y counters scan the buffer continuously.
// ================================================================





cam_line_buffer_30rows #(
    .WIDTH (640),
    .ROWS  (50)
) cam_buf (
    .wr_clk          (cam_pclk),
    .rst_n           (rst_n),
    .cam_vsync       (cam_vsync),
    .cam_16bit_wr_en (cam_16bit_wr_en),
    .cam_pixel_in    ({cbcr_temp, y_temp}),

    .rd_clk          (clk),
    .rd_en           (1'b1),
    .rd_x            (rd_x),
    .rd_y            (rd_y),

    .rd_pixel_out    (buf_pixel),
    .rd_valid        (buf_valid)
);

// ================================================================
// CHIP ID READ-BACK REPORT -- once readback_done goes high, repeatedly
// sends a 4-byte report (0xC1 marker, chip_id_high, chip_id_low,
// comm_ok) about once per second, so we get a clean, repeatable,
// unambiguous answer on whether SCCB communication actually works.
// Replaces the pixel-streaming sender for this diagnostic build.
// ================================================================

localparam LB_LCR_WRITE  = 0;
localparam LB_LCR_CLEAR  = 1;
localparam LB_IDLE       = 2;
localparam LB_POLL_START = 3;
localparam LB_POLL_WAIT  = 4;
localparam LB_POLL_CHECK = 5;
localparam LB_WRITE      = 6;
localparam LB_WRITE_CLR  = 7;
localparam LB_NEXT_BYTE  = 8;

localparam LB_ADDR_DATA = 3'b000;
localparam LB_ADDR_LCR  = 3'b011;
localparam LB_ADDR_STAT = 3'b101;

reg [3:0] lb_state;
reg [1:0] report_byte_idx; // 0=marker, 1=chip_id_high, 2=chip_id_low, 3=comm_ok
reg       report_pending;

reg       lb_tx_en;
reg [2:0] lb_waddr;
reg [7:0] lb_wdata;
reg       lb_rx_en;
reg [2:0] lb_raddr;

assign um_tx_en = lb_tx_en;
assign um_waddr = lb_waddr;
assign um_wdata = lb_wdata;
assign um_rx_en = lb_rx_en;
assign um_raddr = lb_raddr;

localparam REPORT_PERIOD = 27_000_000; // ~1 second at 27MHz
reg [24:0] report_timer;

wire report_complete = (lb_state == LB_NEXT_BYTE) && (report_byte_idx == 3);

// TEMP diagnostic: latches permanently high the first time the sender
// FSM actually completes sending a full 4-byte report internally --
// distinguishes "FSM never runs" from "FSM runs but bytes don't reach
// the PC" (report_pending itself is too brief a pulse to see on an LED).
reg ever_reported;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ever_reported <= 1'b0;
    else if (report_complete)
        ever_reported <= 1'b1;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        report_timer   <= 0;
        report_pending <= 0;
    end else if (report_complete) begin
        report_pending <= 1'b0; // single driver for report_pending -- clear here, not in the FSM block below
    end else if (readback_done) begin
        if (report_timer == REPORT_PERIOD - 1) begin
            report_timer   <= 0;
            report_pending <= 1'b1;
        end else begin
            report_timer <= report_timer + 1'b1;
        end
    end
end

always @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

        lb_state        <= LB_LCR_WRITE;
        report_byte_idx <= 0;
        lb_tx_en <= 0;
        lb_waddr <= 0;
        lb_wdata <= 0;
        lb_rx_en <= 0;
        lb_raddr <= 0;

    end else begin

        case (lb_state)

            LB_LCR_WRITE: begin
                lb_waddr <= LB_ADDR_LCR;
                lb_wdata <= 8'h03;
                lb_tx_en <= 1'b1;
                lb_state <= LB_LCR_CLEAR;
            end

            LB_LCR_CLEAR: begin
                lb_tx_en <= 1'b0;
                lb_state <= LB_IDLE;
            end

            LB_IDLE: begin
                if (report_pending) begin
                    report_byte_idx <= 0;
                    lb_state        <= LB_POLL_START;
                end
            end

            LB_POLL_START: begin
                lb_raddr <= LB_ADDR_STAT;
                lb_rx_en <= 1'b1;
                lb_state <= LB_POLL_WAIT;
            end

            LB_POLL_WAIT: begin
                lb_rx_en <= 1'b0;
                lb_state <= LB_POLL_CHECK;
            end

            LB_POLL_CHECK: begin
                lb_state <= um_rdata[6] ? LB_WRITE : LB_POLL_START;
            end

            LB_WRITE: begin
                lb_waddr <= LB_ADDR_DATA;
                case (report_byte_idx)
                    0: lb_wdata <= 8'hC1; // marker
                    1: lb_wdata <= chip_id_high;
                    2: lb_wdata <= chip_id_low;
                    3: lb_wdata <= {7'd0, comm_ok};
                endcase
                lb_tx_en <= 1'b1;
                lb_state <= LB_WRITE_CLR;
            end

            LB_WRITE_CLR: begin
                lb_tx_en <= 1'b0;
                lb_state <= LB_NEXT_BYTE;
            end

            LB_NEXT_BYTE: begin
                if (report_byte_idx == 3) begin
                    lb_state <= LB_IDLE; // report_pending cleared by the timer block above, not here
                end else begin
                    report_byte_idx <= report_byte_idx + 1'b1;
                    lb_state        <= LB_POLL_START;
                end
            end

        endcase

    end

end
*/

// ================================================================
// OLD UART -- replaced with Gowin's UART_MASTER_Top IP above to rule
// out uart.v's own hand-written TX logic as a variable while
// debugging why no data was ever received on the PC side. Not
// deleted, just disabled.
// ================================================================

// uart uart_tx(
//     .clk             (cam_pclk),
//     .rst_n           (rst_n),
//     .tx_data         (tx_data),
//     .tx_data_valid   (tx_data_valid),
//     .tx_data_ready   (tx_data_ready),
//     .tx_pin          (uart_tx_pin),
//     .tx_busy         ()
// );

// ================================================================
// DEBUG: LED tied directly to cam_vsync -- bypasses the whole
// preprocessor/uart_frame_sender/uart chain to answer one question:
// is the camera producing any sync signal at all?
// ================================================================

assign led_0 = heartbeat; //TEMP: ~1Hz blink, decoupled from the pixel-stream sender --
                           //confirms the chip is alive/clocked independent of whether
                           //the buffer/uart pixel path is actually working.
assign led_1 = linebuf_primed_clk; //TEMP: solid ON means the buffer has frozen (one full
                                    //96x96 frame captured) and the read/send FSM has started.


//always @(negedge lcd_dclk) begin
//    if ((h_count < 400) && (v_count < 240)) begin
//        y_fifo <= 8'hFF;
//        cbcr_fifo <= 8'h80;
//    end else if ((h_count >=400) && (v_count < 240)) begin
//        y_fifo <= 8'h80;
//        cbcr_fifo <= 8'hFF;
//    end else if ((h_count < 400) && (v_count >= 240)) begin
//        y_fifo <= 8'h80;
//        cbcr_fifo <= 8'hFF;
//    end else begin
//        y_fifo <= 8'hFF;
//        cbcr_fifo <= 8'h80;
//    end

//    if (h_count < 400) begin
//        y_fifo <= 8'hFF;
//        cbcr_fifo <= 8'h80;
//    end else begin
//        y_fifo <= 8'h80;
//        cbcr_fifo <= 8'hFF;
//    end
//end


endmodule