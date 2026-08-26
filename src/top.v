module top
(
    input  wire clk,          // 27MHz raw board oscillator, no PLL needed
                               // anymore -- the PLL in the old design only
                               // ever derived the camera's XCLK, which
                               // doesn't exist in this pipeline.
    input  wire rst_n,        // active low

    input  wire uart_rx_pin,  // serial data in from PC (webcam frames)
    output wire uart_tx_pin,  // serial data out to PC -- sends class_result
                               // as a single byte once per completed
                               // classification, for automated test
                               // scripts to read back without needing a
                               // human to check the LEDs each time

    output wire led_0,        // one-hot classifier result, 0-5 fingers
    output wire led_1,
    output wire led_2,
    output wire led_3,
    output wire led_4,
    output wire led_5
);

    //========================================================
    // UART RX -- raw byte stream from the PC
    //========================================================

    wire [7:0] rx_data;
    wire       rx_data_valid;

    uart_rx #(
        .CLK_FRE   (27),      // matches the raw 27MHz oscillator on clk
        .BAUD_RATE (115200)   // see project notes: 921600 doesn't leave
                               // enough timing margin on this un-PLL'd
                               // clock for uart_rx's single-sample (no
                               // oversampling) bit timing.
    ) uart_rx_1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .rx_data       (rx_data),
        .rx_data_valid (rx_data_valid),
        .rx_data_ready (1'b1),   // always ready -- our per-byte processing
                                  // (marker compare / -128 / BSRAM write)
                                  // easily keeps up with UART's byte rate
        .rx_pin        (uart_rx_pin)
    );

    //========================================================
    // FRAME ASSEMBLY -- see uart_frame.v. Watches for the 0xAA 0x55 sync
    // marker (send_frames.py), writes the next 9216 payload bytes into
    // the 96x96 resize BSRAM, centering each pixel the same way
    // preprocessor.v used to (y_data - 128). Replaces preprocessor.v's
    // job entirely -- no DVP timing exists in this pipeline, images
    // already arrive pre-resized to 96x96 from the PC.
    //========================================================

    wire        frame_ready;
    wire [13:0] resize_wr_addr;
    wire [7:0]  resize_wr_data;
    wire        resize_wr_en;
    wire        cnn_busy; // from cnn_top -- gates uart_frame so a new
                           // frame's bytes can't overwrite resize_bsram
                           // while CONV1 is still reading the current one

    uart_frame uart_frame_1 (
        .clk            (clk),
        .rst_n          (rst_n),
        .rx_data        (rx_data),
        .rx_data_valid  (rx_data_valid),
        .busy           (cnn_busy),
        .resize_wr_addr (resize_wr_addr),
        .resize_wr_data (resize_wr_data),
        .resize_wr_en   (resize_wr_en),
        .frame_ready    (frame_ready)
    );

    //========================================================
    // 96x96 RESIZE BSRAM
    //========================================================
    // NEEDS GENERATING via IP Core Generator before this will synthesize
    // -- same process as conv_prom/fc_prom. Simple dual-port pROM won't
    // work here (this one needs real read+write, not just init-and-read),
    // use Gowin_SDPB (Semi-Dual-Port BRAM): depth 9216, width 8, one
    // write port (port A, this frame-assembly logic) and one read port
    // (port B, mac_array). Single clock domain now (both clka/clkb = clk)
    // -- the old design needed cam_pclk/clk cross-domain sync here, this
    // pipeline doesn't since there's no separate camera clock anymore.

    wire [7:0]  resize_dout;
    wire [13:0] resize_addr;
    wire        resize_rd_en;

    Gowin_SDPB resize_bsram (
        .dout   (resize_dout),
        .clka   (clk),
        .cea    (resize_wr_en),
        .reseta (~rst_n),
        .clkb   (clk),
        .ceb    (resize_rd_en),
        .resetb (~rst_n),
        .oce    (1'b1),
        .ada    (resize_wr_addr),
        .din    (resize_wr_data),
        .adb    (resize_addr)
    );

    //========================================================
    // CNN COMPUTE PIPELINE
    //========================================================

    wire        conv_en, conv_done;
    wire        gap_en, gap_done;
    wire        fc_en, fc_done;
    wire [1:0]  conv_layer_sel;
    wire [2:0]  class_result;

    cnn_top cnn_top_1 (

        .rst_n (rst_n),
        .pclk  (clk),           // single clock domain now, no more cam_pclk
        .frame_ready (frame_ready),

        .conv_done (conv_done),
        .pool_done (1'b0),      // vestigial port, unused -- pooling is
                                 // folded into mac_array's own FSM, no
                                 // separate pool stage ever existed
        .gap_done  (gap_done),
        .fc_done   (fc_done),
        .uart_done (1'b0),      // vestigial -- see cnn_top.v's FSM_FC
                                 // comment, output is LEDs now not UART TX

        .conv_en (conv_en),
        .pool_en (),            // vestigial, unused
        .gap_en  (gap_en),
        .fc_en   (fc_en),
        .uart_en (),            // vestigial, unused

        .conv_layer_sel (conv_layer_sel),

        .busy (cnn_busy)

    );

    //========================================================
    // WEIGHT ROM -- already-generated pROM cores (Gowin_pROM_conv /
    // Gowin_pROM_fc), init'd from conv_rom.mi / fc_rom.mi
    //========================================================

    wire [12:0] conv_addr;
    wire [7:0]  fc_addr;
    wire [7:0]  weight_data; // shared bus: weight_rom muxes conv/fc ROM
                              // output internally based on conv_layer_sel,
                              // read by mac_array during conv layers and
                              // classifier during the FC layer -- cnn_top's
                              // FSM guarantees only one is ever active.
    wire [5:0]         bias_addr;  // mac_array -> weight_rom, which filter's bias to read
    wire signed [7:0]  bias_data;  // weight_rom -> mac_array, that filter's bias value

    weight_rom weights (

        .clk            (clk),
        .rst_n          (rst_n),
        .conv_layer_sel (conv_layer_sel),
        .conv_addr      (conv_addr),
        .fc_addr        (fc_addr),
        .bias_addr      (bias_addr),

        .data_out       (weight_data),
        .bias_data_out  (bias_data)

    );

    //========================================================
    // FEATURE MAP BSRAMs -- Feature map A (48x48x8, 18432B), B
    // (24x24x16, 9216B), C (12x12x32, 4608B). NEED GENERATING via IP
    // Core Generator (Gowin_SDPB_A/B/C, no init file needed -- these
    // are scratch buffers written fresh every frame, not weight storage).
    //========================================================

    wire map_a_wr_en, map_b_wr_en, map_c_wr_en;
    wire map_a_rd_en, map_b_rd_en, map_c_rd_en;

    wire [7:0] map_a_din, map_b_din, map_c_din;
    wire [7:0] map_a_dout, map_b_dout, map_c_dout;

    wire [14:0] map_a_wr_addr;
    wire [13:0] map_b_wr_addr;
    wire [12:0] map_c_wr_addr;

    wire [14:0] map_a_rd_addr;
    wire [13:0] map_b_rd_addr;
    wire [12:0] map_c_rd_addr;

    mac_array mac_array_1 (

        .rst_n          (rst_n),
        .clk            (clk),
        .conv_layer_sel (conv_layer_sel),
        .conv_en        (conv_en),

        .conv_done      (conv_done),

        .resize_dout  (resize_dout),
        .resize_addr  (resize_addr),
        .resize_rd_en (resize_rd_en),

        .map_a_wr_en (map_a_wr_en),
        .map_b_wr_en (map_b_wr_en),
        .map_c_wr_en (map_c_wr_en),

        .map_a_rd_en (map_a_rd_en),
        .map_b_rd_en (map_b_rd_en),
        .map_c_rd_en (),   // unused -- mac_array never reads feature map C,
                           // only global_avg_pool does (see its own connection below)

        .map_a_din (map_a_din),
        .map_b_din (map_b_din),
        .map_c_din (map_c_din),

        .map_a_dout (map_a_dout),
        .map_b_dout (map_b_dout),
        .map_c_dout (map_c_dout),

        .map_a_wr_addr (map_a_wr_addr),
        .map_b_wr_addr (map_b_wr_addr),
        .map_c_wr_addr (map_c_wr_addr),

        .map_a_rd_addr (map_a_rd_addr),
        .map_b_rd_addr (map_b_rd_addr),
        .map_c_rd_addr (),   // unused -- same reason as map_c_rd_en above,
                             // mac_array never reads feature map C. Leaving
                             // this wired to the shared net (like map_c_rd_en
                             // correctly isn't) caused a real multi-driver
                             // conflict with global_avg_pool's own drive of
                             // map_c_rd_addr.

        .weight_data (weight_data),
        .conv_addr   (conv_addr),

        .bias_data   (bias_data),
        .bias_addr   (bias_addr)

    );

    Gowin_SDPB_A feature_map_a (
        .dout   (map_a_dout),
        .clka   (clk),
        .cea    (map_a_wr_en),
        .reseta (~rst_n),
        .clkb   (clk),
        .ceb    (map_a_rd_en),
        .resetb (~rst_n),
        .oce    (1'b1),
        .ada    (map_a_wr_addr),
        .din    (map_a_din),
        .adb    (map_a_rd_addr)
    );

    Gowin_SDPB_B feature_map_b (
        .dout   (map_b_dout),
        .clka   (clk),
        .cea    (map_b_wr_en),
        .reseta (~rst_n),
        .clkb   (clk),
        .ceb    (map_b_rd_en),
        .resetb (~rst_n),
        .oce    (1'b1),
        .ada    (map_b_wr_addr),
        .din    (map_b_din),
        .adb    (map_b_rd_addr)
    );

    Gowin_SDPB_C feature_map_c (
        .dout   (map_c_dout),
        .clka   (clk),
        .cea    (map_c_wr_en),
        .reseta (~rst_n),
        .clkb   (clk),
        .ceb    (map_c_rd_en),
        .resetb (~rst_n),
        .oce    (1'b1),
        .ada    (map_c_wr_addr),
        .din    (map_c_din),
        .adb    (map_c_rd_addr)
    );

    //========================================================
    // GLOBAL AVERAGE POOL + CLASSIFIER
    //========================================================

    wire [4:0] gap_addr;
    wire [7:0] gap_data;

    global_avg_pool avg_pool (

        .rst_n (rst_n),
        .clk   (clk),

        .gap_en   (gap_en),
        .gap_done (gap_done),

        .map_c_dout   (map_c_dout),
        .map_c_rd_addr(map_c_rd_addr),
        .map_c_rd_en  (map_c_rd_en),

        .gap_addr (gap_addr),
        .gap_data (gap_data)

    );

    classifier fc_layer (

        .rst_n (rst_n),
        .clk   (clk),

        .fc_en   (fc_en),
        .fc_done (fc_done),

        .gap_addr (gap_addr),
        .gap_data (gap_data),

        .fc_addr     (fc_addr),
        .weight_data (weight_data),

        .class_result (class_result)

    );

    //========================================================
    // UART TX -- sends class_result back to the PC as a single byte
    // whenever a classification completes, for automated test scripts.
    // fc_done is already a clean single-cycle pulse (set once in
    // classifier.v's FSM_ARGMAX, cleared every cycle in FSM_IDLE), safe to
    // use directly as tx_data_valid -- classifications happen roughly once
    // per second, vastly longer than a single byte's ~87us transmission
    // time at 115200 baud, so uart_tx is always idle by the time the next
    // fc_done arrives.
    //========================================================

    wire [7:0] tx_data = {5'd0, class_result};
    wire       tx_data_ready;
    wire       tx_busy;

    uart_tx #(
        .CLK_FRE   (27),
        .BAUD_RATE (115200)
    ) uart_tx_1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .tx_data       (tx_data),
        .tx_data_valid (fc_done),
        .tx_data_ready (tx_data_ready),
        .tx_pin        (uart_tx_pin),
        .tx_busy       (tx_busy)
    );

    //========================================================
    // RESULT OUTPUT -- one-hot LED decoder
    //========================================================
    // Dock-3713 LEDs are active-low (cathode to the FPGA pin) -- driving a
    // pin LOW turns that LED ON. Inverted vs. a naive active-high decoder:
    // each pin is LOW only for its matching class, HIGH (off) otherwise.

    assign led_0 = (class_result != 3'd0);
    assign led_1 = (class_result != 3'd1);
    assign led_2 = (class_result != 3'd2);
    assign led_3 = (class_result != 3'd3);
    assign led_4 = (class_result != 3'd4);
    assign led_5 = (class_result != 3'd5);

endmodule
