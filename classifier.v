module classifier
(
    input  rst_n,
    input  clk,

    input  fc_en,        // start signal from cnn_top
    output reg fc_done,  // done signal to cnn_top

    //========================================================
    // GLOBAL_AVG_POOL READ INTERFACE
    //========================================================

    output [4:0] gap_addr,  // request channel 0-31
    input  [7:0] gap_data,  // averaged value for that channel (combinational, no latency)

    //========================================================
    // WEIGHT_ROM READ INTERFACE (FC weights)
    //========================================================

    output [7:0] fc_addr,     // weight address (0-191)
    input  [7:0] weight_data, // weight value (pROM, 1-cycle latency)

    //========================================================
    // RESULT
    //========================================================

    output reg [2:0] class_result  // argmax winner, 0-5

);

    localparam NUM_IN  = 32;  // inputs from GAP
    localparam NUM_OUT = 6;   // finger-count classes

    reg [4:0] in_idx;    // 0-31
    reg [2:0] out_idx;   // 0-5

    reg signed [7:0]  weight_reg;
    reg signed [7:0]  gap_reg;

    //widened: worst case 32 taps * (127*127) = 516,128 -- needs >=20 bits signed.
    //using 32 bits to match conv_acc.v's accumulator width for consistency.
    reg signed [31:0] acc;
    reg signed [31:0] fc_result [0:5];        // 6 output scores

    //scratch regs for the FSM_ARGMAX comparison chain
    reg [2:0] max_idx;
    reg signed [31:0] max_val;

    //constantly generate the read addresses for the tap we're gathering
    //(same pattern as mac_array/global_avg_pool -- combinational, driven every cycle)
    //weight_rom layout: weight[in_idx][out_idx] stored in_idx-major, out_idx-minor
    assign fc_addr  = in_idx * NUM_OUT + out_idx;
    assign gap_addr = in_idx;

    //========================================================
    // FSM states
    //========================================================

    localparam FSM_IDLE    = 0;
    localparam FSM_GATHER  = 1; // accumulate one output neuron's 32-tap dot product
    localparam FSM_NEXT    = 2; // advance to next output neuron or move to argmax
    localparam FSM_ARGMAX  = 3; // compare all 6 scores, pick the winner

    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state <= FSM_IDLE;
            in_idx <= 0;
            out_idx <= 0;
            acc <= 0;
            fc_done <= 0;
            class_result <= 0;

        end else begin

            case (state)

                FSM_IDLE: begin

                    fc_done <= 0;

                    if (fc_en) begin
                        out_idx <= 0;
                        in_idx <= 0;
                        acc <= 0;
                        state <= FSM_GATHER;
                    end

                end

                FSM_GATHER: begin

                    //same 1-cycle latency pattern as mac_array's FSM_ADDR:
                    //skip the first cycle since weight_data doesn't correspond
                    //to this in_idx's address yet. gap_data is combinational
                    //(no latency) but captured together with weight_data to
                    //keep both operands aligned to the same in_idx.

                    if (in_idx > 0) begin
                        acc <= acc + (weight_reg * gap_reg);
                    end

                    weight_reg <= weight_data;
                    gap_reg    <= gap_data;

                    if (in_idx < NUM_IN) begin
                        in_idx <= in_idx + 1;
                    end else begin
                        state <= FSM_NEXT;
                    end

                end

                FSM_NEXT: begin

                    fc_result[out_idx] <= acc;

                    if (out_idx == NUM_OUT - 1) begin
                        state <= FSM_ARGMAX;
                    end else begin
                        out_idx <= out_idx + 1;
                        in_idx <= 0;
                        acc <= 0;
                        state <= FSM_GATHER;
                    end

                end

                FSM_ARGMAX: begin

                    //blocking assignments here are intentional: each comparison
                    //must see the RESULT of the previous comparison within this
                    //same cycle, not the value from before FSM_ARGMAX started.
                    //max_idx/max_val are scratch-only, never read outside this
                    //block, so blocking assignment is safe and correct here.

                    max_idx = 0;
                    max_val = fc_result[0];

                    if (fc_result[1] > max_val) begin max_val = fc_result[1]; max_idx = 1; end
                    if (fc_result[2] > max_val) begin max_val = fc_result[2]; max_idx = 2; end
                    if (fc_result[3] > max_val) begin max_val = fc_result[3]; max_idx = 3; end
                    if (fc_result[4] > max_val) begin max_val = fc_result[4]; max_idx = 4; end
                    if (fc_result[5] > max_val) begin max_val = fc_result[5]; max_idx = 5; end

                    class_result <= max_idx;

                    fc_done <= 1'b1;
                    state <= FSM_IDLE;

                end

            endcase

        end

    end

endmodule