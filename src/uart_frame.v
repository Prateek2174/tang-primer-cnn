module uart_frame
(
    input        clk,
    input        rst_n,

    input  [7:0] rx_data,
    input        rx_data_valid,

    input        busy, // from cnn_top: high during classification -- holds this
                        // FSM at FR_SEARCH_1 so a new frame can't overwrite
                        // resize_bsram mid-read

    output reg [13:0] resize_wr_addr,
    output reg [7:0]  resize_wr_data,
    output reg        resize_wr_en,
    output reg        frame_ready
);

    //========================================================
    // FRAME ASSEMBLY -- watches for the 0xAA 0x55 sync marker, writes the
    // next 9216 payload bytes into the 96x96 resize BSRAM, centering each
    // pixel (-128). Replaces preprocessor.v -- images already arrive
    // resized to 96x96 from the PC.
    //========================================================

    localparam FR_SEARCH_1 = 2'd0; // waiting for first marker byte (0xAA)
    localparam FR_SEARCH_2 = 2'd1; // waiting for second marker byte (0x55)
    localparam FR_PAYLOAD  = 2'd2; // receiving 9216 payload bytes
    localparam FR_DONE     = 2'd3; // pulse frame_ready, then back to SEARCH_1

    reg [1:0]  fr_state;
    reg [13:0] byte_count;   // 0..9215

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            fr_state       <= FR_SEARCH_1;
            byte_count     <= 0;
            frame_ready    <= 1'b0;
            resize_wr_en   <= 1'b0;
            resize_wr_addr <= 0;
            resize_wr_data <= 0;

        end else begin

            frame_ready  <= 1'b0; // default: single-cycle pulse
            resize_wr_en <= 1'b0; // default: single-cycle write strobe

            if (busy) begin

                // drop any in-flight reception while busy -- sender keeps
                // streaming, next valid marker gets picked up once busy clears
                fr_state   <= FR_SEARCH_1;
                byte_count <= 0;

            end else case (fr_state)

                FR_SEARCH_1: begin
                    if (rx_data_valid && rx_data == 8'hAA)
                        fr_state <= FR_SEARCH_2;
                end

                FR_SEARCH_2: begin
                    if (rx_data_valid) begin
                        if (rx_data == 8'h55) begin
                            fr_state   <= FR_PAYLOAD;
                            byte_count <= 0;
                        end else if (rx_data != 8'hAA) begin
                            fr_state <= FR_SEARCH_1; // not a real marker, resync
                        end
                        // rx_data == 8'hAA again: stay in FR_SEARCH_2
                    end
                end

                FR_PAYLOAD: begin
                    if (rx_data_valid) begin

                        resize_wr_addr <= byte_count;
                        resize_wr_data <= rx_data - 8'd128; // matches
                            // preprocessor.v: y_resize <= y_data - 128
                        resize_wr_en   <= 1'b1;

                        if (byte_count == 14'd9215) begin
                            fr_state <= FR_DONE;
                        end else begin
                            byte_count <= byte_count + 1'b1;
                        end

                    end
                end

                FR_DONE: begin
                    frame_ready <= 1'b1;
                    fr_state    <= FR_SEARCH_1;
                end

            endcase

        end

    end

endmodule
