module mac_array
(
    input rst_n,
    input clk,
    input [1:0] conv_layer_sel, //i need to know which conv layer im on
                                    // 2'b00 = CONV1
                                    // 2'b01 = CONV2
                                    // 2'b10 = CONV3
                                    // 2'b11 = FC

    input conv_en, //stay in idle till this is set
    
    output reg conv_done, //flag for when the conv layer is completed

    //========================================================
    // 96x96 BSRAM
    //========================================================

    input [7:0] resize_dout,   //input -> dout 96x96 [7:0]
    output [13:0] resize_addr, //output -> adb 96x96 [13:0]
    output reg resize_rd_en,       //output -> ceb 96x96

    //========================================================
    // FEATURE MAP BSRAM
    //========================================================

    output reg map_a_wr_en, //input cea MAP A
    output reg map_b_wr_en, //input cea MAP B
    output reg map_c_wr_en, //input cea MAP C

    output reg map_a_rd_en, //input ceb MAP A
    output reg map_b_rd_en, //input ceb MAP B
    output map_c_rd_en, //input ceb MAP C

    output reg [7:0] map_a_din, //input din MAP A
    output reg [7:0] map_b_din, //input din MAP B
    output reg [7:0] map_c_din, //input din MAP C

    input [7:0] map_a_dout, //output dout MAP A
    input [7:0] map_b_dout, //output dout MAP B
    input [7:0] map_c_dout, //output dout MAP C

    output [14:0] map_a_wr_addr, //output ada MAP A adb = rd
    output [13:0] map_b_wr_addr, //output ada MAP B 
    output [12:0] map_c_wr_addr, //output ada/adb MAP C

    output [14:0] map_a_rd_addr, //output adb MAP A adb = rd
    output [13:0] map_b_rd_addr, //output adb MAP B 
    output [12:0] map_c_rd_addr, //output adb MAP C

    //========================================================
    // WEIGHT_ROM
    //======================================================== 

    input  [7:0]  weight_data, 
    output [12:0] conv_addr,

    input signed [7:0] bias_data,
    output       [5:0] bias_addr

);



reg signed [31:0] result [0:3];     //array of 4, 32 bit results from MAC
reg signed [31:0] pool_result;
reg signed [7:0] pixel_data_out; //pool_result needs to be truncated to 8 bits

//looping counters

reg [5:0] out_x;        // output pixel x positions
reg [5:0] out_y;        // output pixel y positions
reg [5:0] filter_index; // filter index

//x and y coordinates for each of the 4 centered MAC

reg [6:0] pool_region_x [0:3]; //is 6 bits enough???????????????????????
reg [6:0] pool_region_y [0:3];
reg [1:0] pool_index;   // keeps count of the 0-3 (4) pool positions

//9 MAC array variables

reg [6:0] mac_array_x [0:8];
reg [6:0] mac_array_y [0:8];
reg [3:0] mac_index; //of the 9 MACs which one we're trying to get data for

reg [4:0] channel_index; //keep count of current channel based on the CONV layer

//Feature map A — 48×48×8  = 18,432 bytes  (Conv1+ReLU+Pool output) 
//Feature map B — 24×24×16 =  9,216 bytes  (Conv2+ReLU+Pool output) 
//Feature map C — 12×12×32 =  4,608 bytes  (Conv3+ReLU+Pool output) 

//for each filter f in 0..7:
//    for each output pixel (ox, oy) in 0..47 × 0..47:
//        compute 4 conv results at input positions:
//            (ox*2,   oy*2)
//            (ox*2+1, oy*2)
//            (ox*2,   oy*2+1)
//            (ox*2+1, oy*2+1)
//        relu each
//        take max
//        write to feature map A at addr = f*2304 + oy*48 + ox


    //========================================================
    // FSM states
    //========================================================    
      
    localparam FSM_IDLE  = 0;
    localparam FSM_COORD = 1; 
    localparam FSM_ADDR  = 2;
    localparam FSM_MAC   = 3;
    localparam FSM_RELU  = 5;
    localparam FSM_POOL  = 6;
    localparam FSM_BOUND = 7;
    localparam FSM_WRITE = 8;
    localparam FSM_DONE  = 9;

    reg [3:0] state;


    //========================================================
    // Select CONV Layer Constants
    //======================================================== 

    //generic temp variables which will be assigned to the relevant BSRAM FEATURE
    //MAP variables/wires based on the CONV layer we're on so multiple if 
    //statements arent required in the FSM

    reg       map_rd_en;
    reg       map_wr_en;
    reg [7:0] map_dout; //feature map output data
    reg [7:0] map_din;  //feature map input data
    
    wire [14:0] map_rd_addr; //matches the largest addr bit field
    reg [14:0] map_wr_addr; 


    reg [6:0] frame;
    reg [5:0] num_filters;
    reg [6:0] in_width;

    reg [3:0] rescale_shift; //per layer right shift before saturation
                             //apply this in FSM_BOUND

    reg [5:0] bias_layer_base; //offset in the 56 entry bias ROM
    reg signed [7:0] bias_reg; //bias for current filter

    assign bias_addr = bias_layer_base + filter_index;

    //Conv1: base = 0     (8 filters × 9 mac × 1 channel = 72)
    //Conv2: base = 72    (16 filters × 9 mac × 8 channels = 1152)
    //Conv3: base = 1224  (32 filters × 9 mac × 16 channels = 4608)

    reg [12:0] conv_layer_base; //needed to access the correct addr location for
                               //the weights -> output [12:0] conv_addr

    reg [4:0] channels_per_filter;
    reg [4:0] num_channels;

    assign conv_addr = conv_layer_base + filter_index * (9 * channels_per_filter)
                        + channel_index * 9 + mac_index;

    always @(*) begin

        // Safe defaults for every signal this block can drive, BEFORE the
        // case statement -- standard idiom for a case-based mux. Without
        // this, any signal not touched by a given branch (e.g. map_a_wr_en
        // during CONV2/CONV3, since only ONE layer's wr_en is set per
        // branch) infers a latch instead of clean combinational logic --
        // confirmed by synthesis for resize_rd_en, and the same structural
        // gap existed for map_a/b/c_wr_en, map_a/b_rd_en, map_din, and
        // num_channels too (not yet flagged individually only because the
        // map_wr_en multi-driver error below was stopping deeper analysis).
        // map_wr_en, map_rd_en, and map_dout are deliberately NOT defaulted
        // here -- they're owned exclusively by the clocked FSM, this block
        // only ever reads them (assigning map_wr_en here caused the actual
        // multi-driver error; the ORIGINAL code had the identical bug on
        // map_dout too, in its old default case -- just not yet reported,
        // most likely because synthesis was still stuck on map_wr_en).

        frame = 0;
        num_filters = 0;
        in_width = 0;
        num_channels = 0;
        conv_layer_base = 0;
        channels_per_filter = 0;
        rescale_shift = 4'd0;
        bias_layer_base = 6'd0;

        resize_rd_en = 1'b0;
        map_a_wr_en  = 1'b0;
        map_b_wr_en  = 1'b0;
        map_c_wr_en  = 1'b0;
        map_a_rd_en  = 1'b0;
        map_b_rd_en  = 1'b0;
        map_din      = 8'd0;
        map_a_din    = 8'd0;
        map_b_din    = 8'd0;
        map_c_din    = 8'd0;

        case (conv_layer_sel)

            2'b00: begin //96x96 -> 48x48x8

                frame = 48;
                num_filters = 8;
                in_width = 96;
                num_channels = 1;

                resize_rd_en = map_rd_en; //96x96   rd
                map_a_wr_en = map_wr_en;  //48x48x8 wr
                map_din   = resize_dout;  //96x96 ->
                map_a_din = map_dout;     //-> 48x48

                conv_layer_base = 0;
                channels_per_filter = 1;
                rescale_shift = 4'd3; //calibrated from trained weights CONV1
                bias_layer_base = 6'd0; //filters 0-7

            end

            2'b01: begin //48x48x8 -> 24x24x16

                frame = 24;
                num_filters = 16;
                in_width = 48;
                num_channels = 8;

                map_a_rd_en = map_rd_en;
                map_b_wr_en = map_wr_en;
                map_din   = map_a_dout;
                map_b_din = map_dout;

                conv_layer_base = 72;
                channels_per_filter = 8;
                rescale_shift = 4'd4;
                bias_layer_base = 6'd8; //filters 0-15

            end

            2'b10: begin //24x24x16 -> 12x12x32

                frame = 12;
                num_filters = 32;
                in_width = 24;
                num_channels = 16;

                map_b_rd_en = map_rd_en;
                map_c_wr_en = map_wr_en;
                map_din   = map_b_dout;
                map_c_din = map_dout;

                conv_layer_base = 1224;
                channels_per_filter = 16;
                rescale_shift = 4'd5;
                bias_layer_base = 6'd24;

            end

            default: begin
                // FC layer (2'b11) and any unused encoding -- every signal
                // already has a safe default above, nothing layer-specific
                // to drive here.
            end

        endcase

    end

    //tie addr_map outputs to the generic map_addr variables

    assign resize_addr = map_rd_addr[13:0];
    assign map_a_rd_addr  = map_rd_addr;
    assign map_b_rd_addr  = map_rd_addr[13:0];
    assign map_c_rd_addr  = map_rd_addr[12:0];

    assign map_a_wr_addr  = map_wr_addr;
    assign map_b_wr_addr  = map_wr_addr[13:0];
    assign map_c_wr_addr  = map_wr_addr[12:0];

    //need to rescale the pooled accumulator before bounding/saturating
    wire signed [31:0] scaled_result = pool_result >>> rescale_shift;

    //========================================================
    // 9 MAC Pixel Locations
    //======================================================== 

    reg [1:0] fr, fc;

    always @(*) begin

        case (mac_index)

            0: begin fr=0; fc=0; end
            1: begin fr=0; fc=1; end
            2: begin fr=0; fc=2; end
            3: begin fr=1; fc=0; end
            4: begin fr=1; fc=1; end
            5: begin fr=1; fc=2; end
            6: begin fr=2; fc=0; end
            7: begin fr=2; fc=1; end
            8: begin fr=2; fc=2; end
            default: begin fr=0; fc=0; end

        endcase
    end

    //constantly generate the next 9 MAC pixel

    wire signed [7:0] mac_x = pool_region_x[pool_index] + fc - 1;
    wire signed [7:0] mac_y = pool_region_y[pool_index] + fr - 1;

    //need to guard from trying to access negative pixel locations:

    wire mac_valid = (mac_x >= 0) && (mac_x < in_width) && (mac_y >= 0) && (mac_y < in_width); //is the next 9 MAC pixel valid
    assign map_rd_addr = mac_valid ? (channel_index * in_width * in_width + mac_y * in_width + mac_x) : 15'd0;  // address doesn't matter if invalid

    // Documented, known tradeoff from earlier training work (see model.py's
    // docstring): when mac_valid=0, map_rd_addr defaults to address 0 of
    // the CURRENT channel instead of skipping the read -- meaning an
    // out-of-bounds conv tap was reading a real (wrong) pixel value there
    // instead of the zero-padding the model was actually trained to
    // expect. mac_valid itself is combinational and changes every cycle as
    // mac_index advances, so it has to be pipelined through the same
    // 2-cycle delay as map_din/weight_data to correctly gate the capture
    // for the SAME tap it was computed for, not whatever tap mac_valid
    // happens to show 2 cycles later.
    reg mac_valid_stage1, mac_valid_stage2;

    //========================================================
    // Main FSM
    //========================================================  

    always @(posedge clk or negedge rst_n) begin
    
        if(!rst_n) begin

            state <= FSM_IDLE;
            
            out_x <= 0;        
            out_y <= 0;  
            filter_index <= 0;  

            pool_index <= 0;   
            mac_index <= 0; //of the 9 MACs which one we're trying to get data for
            channel_index <= 0;

            pool_region_x[0] <= 0;
            pool_region_x[1] <= 0;
            pool_region_x[2] <= 0;
            pool_region_x[3] <= 0;

            pool_region_y[0] <= 0;
            pool_region_y[1] <= 0;
            pool_region_y[2] <= 0;
            pool_region_y[3] <= 0;

            mac_array_x[0] <= 0;
            mac_array_x[1] <= 0;
            mac_array_x[2] <= 0;
            mac_array_x[3] <= 0;
            mac_array_x[4] <= 0;
            mac_array_x[5] <= 0;
            mac_array_x[6] <= 0;
            mac_array_x[7] <= 0;
            mac_array_x[8] <= 0;

            mac_array_y[0] <= 0;
            mac_array_y[1] <= 0;
            mac_array_y[2] <= 0;
            mac_array_y[3] <= 0;
            mac_array_y[4] <= 0;
            mac_array_y[5] <= 0;
            mac_array_y[6] <= 0;
            mac_array_y[7] <= 0;
            mac_array_y[8] <= 0;

            //result array for the 4 pool regions 9 MACs
            result[0] <= 0;
            result[1] <= 0;
            result[2] <= 0;
            result[3] <= 0;
            
            conv_done <= 0;

            mac_valid_stage1 <= 1'b0;
            mac_valid_stage2 <= 1'b0;

            acc_in_en <= 0;
            bias_reg <= 0;
            pool_result <= 0;
            pixel_data_out <= 0;
            
        end else begin

            case(state)

                //compare out_x with frame for looping

                FSM_IDLE: begin

                    // conv_done must self-clear here every idle cycle --
                    // same pattern classifier.v (fc_done) and
                    // global_avg_pool.v (gap_done) already use in their own
                    // FSM_IDLE. Without this, conv_done latches high after
                    // CONV1 finishes and never returns to 0, so cnn_top's
                    // `if(conv_done)` check in FSM_CONV2/FSM_CONV3 is true
                    // on literally the first cycle of each state -- both
                    // layers get skipped entirely (~0 real cycles) instead
                    // of actually running, leaving feature map C all zeros,
                    // which makes every FC output score tie at exactly 0
                    // and the strict `>` argmax always default to index 0.
                    conv_done <= 1'b0;

                    if (conv_en == 1'b1) begin

                        // out_x/out_y/filter_index must reset here too --
                        // they're only reset on global rst_n otherwise, so
                        // CONV2/CONV3 previously started from CONV1's
                        // leftover values (e.g. out_x=47,out_y=47 for
                        // CONV1's 48-wide frame). Against CONV2's smaller
                        // frame=24, that stale out_x/out_y immediately fails
                        // its own bounds check in FSM_DONE while the stale
                        // filter_index still passed, so the layer's
                        // completion logic fired almost immediately and
                        // skipped filters 0-7 of CONV2 entirely -- leaving
                        // those feature-map-B channels permanently
                        // unwritten (X in simulation), which propagates
                        // into fc_result[] and makes the argmax's `>`
                        // comparisons always evaluate false, so class_result
                        // was stuck at its initial value of 0 regardless of
                        // the real input image.
                        out_x <= 0;
                        out_y <= 0;
                        filter_index <= 0;

                        state <= FSM_COORD;

                    end

                end

                //============================================
                //
                //============================================
                FSM_COORD: begin

                    //go from out_x and out_y to address of the (2,2) data in
                    //BSRAM so i can access it. so 4 centered 3x3 patches

                    pool_region_x[0] <= out_x*2;
                    pool_region_x[1] <= out_x*2 + 1;
                    pool_region_x[2] <= out_x*2;
                    pool_region_x[3] <= out_x*2 + 1;

                    pool_region_y[0] <= out_y*2;
                    pool_region_y[1] <= out_y*2;
                    pool_region_y[2] <= out_y*2 + 1;
                    pool_region_y[3] <= out_y*2 + 1;

                    //reset the result array before the channel looping
                    result[0] <= 0;
                    result[1] <= 0;
                    result[2] <= 0;
                    result[3] <= 0;

                    // mac_index/channel_index must reset here too -- they're
                    // only reset when FSM_MAC advances pool_index WITHIN a
                    // position (0->1->2->3), never when pool_index wraps
                    // from 3 back to 0 for a brand NEW position. That left
                    // pool_index=0 of every single (x,y) position starting
                    // with mac_index stuck at its previous position's final
                    // value (10) -- immediately failing its own
                    // `mac_index<10` check and skipping straight to
                    // FSM_MAC without ever capturing real tap data, so
                    // mac_pixel_data[]/mac_weight[] still held garbage left
                    // over from the PREVIOUS position's last pool_index=3
                    // sub-window. Same issue for channel_index on
                    // multi-channel layers (CONV2/CONV3): it'd start
                    // already at num_channels-1 (inherited from the
                    // previous position's last accumulate), immediately
                    // satisfying the "last channel" exit condition after
                    // just one real accumulate and skipping the rest.
                    // Invisible on CONV1 specifically (num_channels=1, so
                    // channel_index=0 is trivially always correct anyway),
                    // which is exactly why this was still uncaught after
                    // fixing the very similar out_x/out_y/filter_index bug.
                    mac_index <= 0;
                    channel_index <= 0;

                    // bias_reg capture moved into FSM_ADDR (see there) --
                    // bias_addr can change on literally this same cycle
                    // (right after filter_index advances in FSM_DONE), so
                    // capturing bias_data here gives it zero settling time
                    // against the real 2-cycle pROM latency, reading the
                    // PREVIOUS filter's bias for the first position of
                    // every new filter. Only matters once per filter (144
                    // positions redundantly re-capture the same stable
                    // address the rest of the time), but it's the same
                    // root cause as the main fix, so worth doing right.

                    state <= FSM_ADDR;

                end

                //============================================
                //
                //============================================
                FSM_ADDR: begin

                    // current 9 MAC center

                    // pool_region_x[pool_index]
                    // pool_region_y[pool_index]

                    // map_rd_en -- generic data en from relevant layer
                    // map_din -- generic data in from addr being accessed


                    // Real Gowin BRAM/pROM primitives for these specific
                    // depths (not a power of 2) get split across multiple
                    // physical blocks internally, muxed by an address-range
                    // selector that's itself pushed through 2 cascaded
                    // DFFEs to stay aligned with the underlying block's own
                    // registered output -- verified directly against
                    // Gowin's real GW2A simulation primitives (prim_sim.v):
                    // both Gowin_SDPB (map_din) and Gowin_pROM_conv
                    // (weight_data) take 2 full cycles from address-in to
                    // valid-data-out, not 1. Skip the first TWO cycles here
                    // (was 1) to match -- capturing 1 cycle early silently
                    // read stale, one-address-behind data for every single
                    // tap of every position.

                    // pipeline mac_valid through the same 2-cycle delay as
                    // map_din, so mac_valid_stage2 reflects validity for
                    // the SAME tap map_din is now returning data for (see
                    // mac_valid_stage1/2 declaration comment above)
                    mac_valid_stage1 <= mac_valid;
                    mac_valid_stage2 <= mac_valid_stage1;

                    if (mac_index > 1) begin

                        mac_pixel_data[mac_index - 2] <= mac_valid_stage2 ? map_din : 8'sd0;
                        mac_weight[mac_index - 2] <= weight_data;

                    end

                    // bias_addr became stable no later than FSM_COORD (1
                    // cycle before this state), so by the time mac_index
                    // reaches 2 here it's had >= 3 cycles to settle --
                    // comfortably past the 2-cycle pROM latency.
                    if (mac_index == 4'd2) begin
                        bias_reg <= bias_data;
                    end

                    if (mac_index < 10) begin

                        map_rd_en <= 1'b1;
                        mac_index <= mac_index + 1;

                    end else begin

                        state <= FSM_MAC;

                    end

                    //get pixel and weight data needed

                    //reg signed [7:0] mac_weight [0:8];

                    //input  [7:0]  weight_data, 
                    //output [12:0] conv_addr    

                    // map_rd_en;
                    // map_wr_en;
                    // map_dout; //feature map output data
                    // map_din;  //feature map input data

                end

                //============================================
                //
                //============================================
                FSM_MAC: begin
                    
                    acc_in_en <= 1'b1;

                    if(acc_out_en) begin
                    
                        result[pool_index] <= result[pool_index] + acc_temp;
                        acc_in_en <= 1'b0; //reset

                        if(channel_index == num_channels - 1) begin

                            if(pool_index == 3) begin

                                pool_index <= 0;
                                state <= FSM_RELU;
                
                            end else begin

                                pool_index <= pool_index + 1'b1;
                                channel_index <= 0;
                                mac_index <= 0;
                                state <= FSM_ADDR;
        
                            end

                        end else begin

                            channel_index <= channel_index + 1'b1;
                            mac_index <= 0;
                            state <= FSM_ADDR;

                        end

                    end
                    

                end

                //============================================
                //
                //============================================
                FSM_RELU: begin
                    
                    // ReLU

// bias, THEN ReLU -- matches "conv then bias then
                    // activation", and exactly what the Python model
                    // (model_bias.py) computed during training.
                    // Both ternary branches must be explicitly signed
                    // (32'sd0, not 32'd0) -- mixing a signed and unsigned
                    // branch makes Verilog treat the WHOLE conditional
                    // expression as unsigned, which was reinterpreting a
                    // negative bias_reg (e.g. -1) as its huge unsigned
                    // equivalent (255) in the true-branch computation.
                    // Empirically confirmed: filter 7's bias=-1 was adding
                    // +255 instead of -1 to the raw accumulator, a +256
                    // excess that exactly explained the corrupted output
                    // (verified against a hand-computed reference before
                    // and after this fix). Invisible for filter 0 earlier
                    // in this same debug session only because its bias
                    // happened to be exactly 0.
                    result[0] <= (result[0] + bias_reg) < 32'sd0 ? 32'sd0 : (result[0] + bias_reg);
                    result[1] <= (result[1] + bias_reg) < 32'sd0 ? 32'sd0 : (result[1] + bias_reg);
                    result[2] <= (result[2] + bias_reg) < 32'sd0 ? 32'sd0 : (result[2] + bias_reg);
                    result[3] <= (result[3] + bias_reg) < 32'sd0 ? 32'sd0 : (result[3] + bias_reg);
      
                    state <= FSM_POOL;

                end

                //============================================
                //
                //============================================
                FSM_POOL: begin

                    //maxpool the 4 results
                    //[ 3  7 ]
                    //[ 1  5 ]  →  7

                    // Blocking assignments here are intentional -- same
                    // reason as classifier.v's FSM_ARGMAX comparison chain:
                    // each comparison must see the RESULT of the previous
                    // comparison within this same cycle, not pool_result's
                    // stale value from a PREVIOUS position's FSM_POOL. With
                    // non-blocking assignment (the original bug), every
                    // `if(resultN > pool_result)` compared against
                    // whatever pool_result happened to hold from the last
                    // time this state ran -- completely unrelated to
                    // result[0..3] -- so the final pool_result was
                    // essentially garbage whenever any of those stale
                    // comparisons happened to come out true.

                    pool_result = result[0];

                    if(result[1] > pool_result) pool_result = result[1];
                    if(result[2] > pool_result) pool_result = result[2];
                    if(result[3] > pool_result) pool_result = result[3];

                    state <= FSM_BOUND;

                end

                //============================================
                //Saturate or truncate pool_result to ensure its within 8 bits
                //============================================
                FSM_BOUND: begin
                    
                    if(scaled_result > 127) begin

                        pixel_data_out <= 127;

                    end else if(scaled_result < -128) begin

                        pixel_data_out <= -128;

                    end else begin

                        pixel_data_out <= scaled_result[7:0];

                    end
                    
                    state <= FSM_WRITE;

                end

                //============================================
                //
                //============================================
                FSM_WRITE: begin
                    
                    //write the result into BSRAM feature map
                    //calculate addr location
                    //access addr location
                    map_wr_addr <= filter_index * (frame*frame) + out_y * frame + out_x;

                    map_wr_en <= 1'b1; //enable writing to BSRAM MAP
                    map_dout <= pixel_data_out;//write to relevant BSRAM MAP

                    state <= FSM_DONE;

                end

                //============================================
                //
                //============================================
                FSM_DONE: begin

                    //out_x vs frame
                    //out_y vs frame
                    //filter_index vs num_filters 

                    map_wr_en <= 1'b0;

                    if (out_x < frame - 1) begin

                        out_x <= out_x + 1;
                        state <= FSM_COORD;

                    end else if (out_y < frame - 1) begin

                        out_x <= 0;
                        out_y <= out_y + 1;
                        state <= FSM_COORD;

                    end else if (filter_index < num_filters - 1) begin

                        out_x <= 0;
                        out_y <= 0;
                        filter_index <= filter_index + 1;
                        state <= FSM_COORD;

                    end else begin

                        conv_done <= 1'b1;
                        state <= FSM_IDLE;

                    end

                end


            endcase

        end

    end

    //========================================================
    // 9 MACs ACC Calculation
    //======================================================== 

reg acc_in_en;
wire acc_out_en;

wire signed [71:0] pixel_bus;
wire signed [71:0] weight_bus;

reg signed [7:0] mac_pixel_data  [0:8];
reg signed [7:0] mac_weight [0:8];

//temp accumulate variable so result[pool_index] doesn't get overwritten
//when looping over channels
wire signed [31:0] acc_temp;

assign pixel_bus = {mac_pixel_data[0], mac_pixel_data[1], mac_pixel_data[2],
                    mac_pixel_data[3], mac_pixel_data[4], mac_pixel_data[5],
                    mac_pixel_data[6], mac_pixel_data[7], mac_pixel_data[8]};

assign weight_bus = {mac_weight[0], mac_weight[1], mac_weight[2],
                     mac_weight[3], mac_weight[4], mac_weight[5],
                     mac_weight[6], mac_weight[7], mac_weight[8]};

conv_acc #(.DATA_W(8), .ACC_W (32)) conv_core_acc (

    //IN

    .clk        (clk),
    .rst_n      (rst_n),
    .acc_in_en  (acc_in_en),
                
    .window_in  (pixel_bus),  //9 pixels for the 9 MACs
    .weight_in  (weight_bus), //9 weights from weight_rom.v

    //OUT

    .acc_out_en (acc_out_en), 
    .acc_out    (acc_temp)
);  



endmodule