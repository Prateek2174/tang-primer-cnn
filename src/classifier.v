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
    input  [7:0] weight_data, // weight value (pROM, 2-cycle latency --
                               // verified against Gowin's real GW2A
                               // simulation primitives: this depth isn't a
                               // power of 2, so the IP generator splits it
                               // across multiple physical blocks with a
                               // 2-cycle address-to-data latency, not 1)

    //========================================================
    // RESULT
    //========================================================

    output reg [2:0] class_result  // argmax winner, 0-5

);

    localparam NUM_IN  = 32;  // inputs from GAP
    localparam NUM_OUT = 6;   // finger-count classes

    reg [5:0] in_idx;    // 0-31, counts up to 32 (exit value) before wrapping --
                         // must be wider than 5 bits or in_idx+1 truncates
                         // 32 back to 0 and FSM_GATHER never exits (same
                         // counter-width headroom mac_array.v's mac_index uses
                         // for its own exit value of 9 vs its 4-bit width)
    reg [2:0] out_idx;   // 0-5

    reg signed [7:0]  weight_reg;
    reg signed [7:0]  gap_reg;
    reg signed [7:0]  gap_reg_stage1, gap_reg_stage2;
    // Pipeline depth here (3 total stages: stage1, stage2, gap_reg) was
    // determined empirically, not analytically -- a precise edge-by-edge
    // probe against Gowin's real GW2A simulation primitives measured the
    // real pROM's address-to-data latency at exactly 3 clock edges. But a
    // first analytical attempt to translate that into "how many pipeline
    // stages does gap_data need" got the wrong answer (over-thought the
    // weight_reg/acc same-cycle NBA interaction and guessed 4 stages,
    // which gave a provably wrong dot-product result against a
    // hand-computed reference). Swept 2/3/4/5 stages against a
    // hand-computed expected value (real fc_rom.mi weights times a
    // trivial gap_data[k]=k test pattern) and only 3 stages reproduced
    // the exact expected accumulator value -- trust this over any
    // re-derivation from first principles.

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

                    // 2-cycle latency pattern (verified against Gowin's
                    // real GW2A pROM/BRAM simulation primitives -- see
                    // weight_data's port comment): skip the first THREE
                    // cycles (verified empirically, see gap_reg_stage
                    // declaration comment) since weight_data doesn't
                    // correspond to this in_idx's address yet. gap_data is
                    // combinational, so it's pushed through a matching
                    // 3-stage pipeline to stay aligned with weight_reg when
                    // finally multiplied.

                    if (in_idx > 2) begin
                        acc <= acc + (weight_reg * gap_reg);
                    end

                    weight_reg     <= weight_data;
                    gap_reg        <= gap_reg_stage2;
                    gap_reg_stage2 <= gap_reg_stage1;
                    gap_reg_stage1 <= gap_data;

                    if (in_idx < NUM_IN + 2) begin
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