module cam_line_buffer_30rows #(
    parameter WIDTH = 640,
    parameter ROWS  = 50
)(
    // Camera write side
    input  wire        wr_clk,
    input  wire        rst_n,
    input  wire        cam_vsync,         // pulse/high at start of new frame
    input  wire        cam_16bit_wr_en,   // write one 16-bit pixel when high
    input  wire [15:0] cam_pixel_in,      // {cbcr, y} or whatever 16-bit format you use

    // Display read side
    input  wire        rd_clk,
    input  wire        rd_en,
    input  wire [10:0] rd_x,              // 0 .. WIDTH-1
    input  wire [9:0]  rd_y,              // display y coordinate

    output reg  [15:0] rd_pixel_out,
    output reg         rd_valid
);

    localparam DEPTH = WIDTH * ROWS;

    // Storage
    reg [15:0] mem [0:DEPTH-1];

    // Write-side position
    reg [10:0] wr_x;
    reg [5:0]  wr_row;

    // ------------------------------------------------------------
    // Write side
    // ------------------------------------------------------------
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_x   <= 11'd0;
            wr_row <= 6'd0;
        end else begin
            // New frame: restart writing from row 0
            if (cam_vsync) begin
                wr_x   <= 11'd0;
                wr_row <= 6'd0;
            end else if (cam_16bit_wr_en) begin
                mem[wr_row * WIDTH + wr_x] <= cam_pixel_in;

                if (wr_x == WIDTH-1) begin
                    wr_x <= 11'd0;

                    if (wr_row == ROWS-1)
                        wr_row <= 6'd0;
                    else
                        wr_row <= wr_row + 6'd1;
                end else begin
                    wr_x <= wr_x + 11'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // Read side
    // ------------------------------------------------------------
    wire [5:0]  rd_row_mod  = rd_y % ROWS;
    wire [15:0] rd_addr_calc = rd_row_mod * WIDTH + rd_x;

    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_pixel_out <= 16'd0;
            rd_valid     <= 1'b0;
        end else if (rd_en) begin
            if (rd_x < WIDTH) begin
                rd_pixel_out <= mem[rd_addr_calc];
                rd_valid     <= 1'b1;
            end else begin
                rd_pixel_out <= 16'd0;
                rd_valid     <= 1'b0;
            end
        end else begin
            rd_valid <= 1'b0;
        end
    end

endmodule
