module buffer #(
    parameter WIDTH = 640,
    parameter ROWS  = 100  // 640*100*8 = 512,000 bits, matching the original
                            // cam_line_buffer_30rows.v's 640*50*16 exactly, with
                            // headroom left for the still-present 96x96 BSRAM
                            // elsewhere in the design (total device BRAM is
                            // ~828,000 bits -- 150 rows here plus that other
                            // buffer overflowed it, causing a BRAM->FF inference
                            // fallback and a DFF resource error)
)(
    // Camera write side
    input  wire       wr_clk,
    input  wire       rst_n,
    input  wire       cam_vsync,       // pulse/high at start of new frame
    input  wire       cam_wr_en,       // write one 8-bit Y pixel when high
    input  wire [7:0] cam_pixel_in,    // Y only

    // Display read side
    input  wire        rd_clk,
    input  wire        rd_en,
    input  wire [10:0] rd_x,              // 0 .. WIDTH-1
    input  wire [9:0]  rd_y,              // display y coordinate

    output reg  [7:0] rd_pixel_out,
    output reg        rd_valid
);

    localparam DEPTH = WIDTH * ROWS;

    // Storage -- 8 bits/pixel (Y only)
    reg [7:0] mem [0:DEPTH-1];

    // Track which stored rows contain valid data from the current frame
    reg [ROWS-1:0] row_valid;

    // Write-side position
    reg [10:0] wr_x;
    reg [7:0]  wr_row;   // widened from 6 to 8 bits to cover ROWS up to 255

    integer i;

    // ------------------------------------------------------------
    // Write side
    // ------------------------------------------------------------
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_x      <= 11'd0;
            wr_row    <= 8'd0;
            row_valid <= {ROWS{1'b0}};
        end else begin
            // New frame: restart write position, but do NOT clear row_valid
            // here -- the caller (top.v) permanently gates cam_wr_en off
            // after one full capture (freeze-after-one-cycle), and cam_vsync
            // itself is NOT gated (the real camera keeps generating vsync
            // pulses forever). Clearing row_valid on every vsync -- even
            // pulses long after the freeze -- wiped every row back to
            // "invalid" moments after capture, making every read return
            // zero permanently. row_valid now only ever needs to go from
            // all-0 (at reset) to set-as-written, and stay that way.
            if (cam_vsync) begin
                wr_x      <= 11'd0;
                wr_row    <= 8'd0;
            end

            if (cam_wr_en) begin
                mem[wr_row * WIDTH + wr_x] <= cam_pixel_in;
                row_valid[wr_row]          <= 1'b1;

                if (wr_x == WIDTH-1) begin
                    wr_x <= 11'd0;

                    if (wr_row == ROWS-1)
                        wr_row <= 8'd0;
                    else
                        wr_row <= wr_row + 8'd1;
                end else begin
                    wr_x <= wr_x + 11'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // Read side
    // ------------------------------------------------------------
    // Reads row rd_y modulo ROWS.
    // If that stored row has not been written in the current frame,
    // output zero and rd_valid=0.
    // ------------------------------------------------------------
    wire [7:0]  rd_row_mod   = rd_y % ROWS;
    wire [17:0] rd_addr_calc = rd_row_mod * WIDTH + rd_x; // widened for DEPTH up to 640*255

    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_pixel_out <= 8'd0;
            rd_valid     <= 1'b0;
        end else if (rd_en) begin
            if ((rd_x < WIDTH) && row_valid[rd_row_mod]) begin
                rd_pixel_out <= mem[rd_addr_calc];
                rd_valid     <= 1'b1;
            end else begin
                rd_pixel_out <= 8'd0;
                rd_valid     <= 1'b0;
            end
        end else begin
            rd_valid <= 1'b0;
        end
    end

endmodule