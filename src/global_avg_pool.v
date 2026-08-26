module global_avg_pool
(
    input  rst_n,
    input  clk,

    input  gap_en,       // start signal from cnn_top
    output reg gap_done, // done signal to cnn_top

    //========================================================
    // FEATURE MAP C BSRAM (12x12x32)
    //========================================================

    input  [7:0] map_c_dout,      // input <- dout MAP C
    output [12:0] map_c_rd_addr,  // output -> adb MAP C
    output reg map_c_rd_en,       // output -> ceb MAP C

    //========================================================
    // GAP RESULT READ INTERFACE (for classifier.v)
    //========================================================

    input  [4:0] gap_addr,   // classifier requests channel 0-31
    output [7:0] gap_data    // averaged value for that channel

);

    localparam CH_SIZE = 144;  // 12*12 pixels per channel
    localparam NUM_CH  = 32;   // channels in feature map C

    reg [4:0] channel_index;   // 0-31
    reg [7:0] pixel_index;     // 0-143

    reg signed [17:0] acc;     // running sum, max 144*127=18288

    reg signed [7:0] gap_result [0:31]; // 32 averaged int8 values

    assign gap_data = gap_result[gap_addr];

    //constantly generate the read address for the pixel we're gathering
    //(same pattern as mac_array's map_rd_addr -- combinational, driven every cycle)
    assign map_c_rd_addr = channel_index * CH_SIZE + pixel_index;

    //========================================================
    // FSM states
    //========================================================

    localparam FSM_IDLE    = 0;
    localparam FSM_GATHER  = 1; // accumulate one channel's 144 pixels
    localparam FSM_DIVIDE  = 2; // approximate divide, store result
    localparam FSM_NEXT    = 3; // advance to next channel or finish

    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state <= FSM_IDLE;
            channel_index <= 0;
            pixel_index <= 0;
            acc <= 0;
            gap_done <= 0;
            map_c_rd_en <= 0;

        end else begin

            case (state)

                FSM_IDLE: begin

                    gap_done <= 0;

                    if (gap_en) begin
                        channel_index <= 0;
                        pixel_index <= 0;
                        acc <= 0;
                        state <= FSM_GATHER;
                    end

                end

                FSM_GATHER: begin

                    // 2-cycle BSRAM latency (verified against Gowin's real
                    // GW2A simulation primitives -- feature_map_c's
                    // non-power-of-2 depth splits it across multiple
                    // physical blocks internally, giving a real 2-cycle
                    // address-to-data latency, not 1): skip the first TWO
                    // cycles since map_c_dout doesn't correspond to this
                    // pixel_index's address yet.

                    if (pixel_index > 1) begin
                        acc <= acc + map_c_dout;
                    end

                    if (pixel_index < CH_SIZE + 1) begin
                        map_c_rd_en <= 1'b1;
                        pixel_index <= pixel_index + 1;
                    end else begin
                        state <= FSM_DIVIDE;
                    end

                end

                FSM_DIVIDE: begin

                    //approximate divide by 144 via right-shift by 7 (divide by 128)
                    //avoids a real divider circuit; close enough for this application

                    state <= FSM_NEXT;

                    if (acc >>> 7 > 127) begin

                        gap_result[channel_index] <= 127;

                    end else begin

                        gap_result[channel_index] <= acc >>> 7;

                    end

                end

                FSM_NEXT: begin

                    if (channel_index == NUM_CH - 1) begin
                        gap_done <= 1'b1;
                        state <= FSM_IDLE;
                    end else begin
                        channel_index <= channel_index + 1;
                        pixel_index <= 0;
                        acc <= 0;
                        state <= FSM_GATHER;
                    end

                end

            endcase

        end

    end

endmodule