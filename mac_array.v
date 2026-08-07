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
    
    output conv_done, //flag for when the conv layer is completed

    //========================================================
    // 96x96 BSRAM
    //======================================================== 

    input [7:0] resize_dout,   //input -> dout 96x96 [7:0]
    output [13:0] resize_addr, //output -> adb 96x96 [13:0]
    output resize_rd_en,       //output -> ceb 96x96  

    //========================================================
    // FEATURE MAP BSRAM
    //======================================================== 

    output map_a_wr_en, //input cea MAP A
    output map_b_wr_en, //input cea MAP B
    output map_c_wr_en, //input cea MAP C

    output map_a_rd_en, //input ceb MAP A
    output map_b_rd_en, //input ceb MAP B
    output map_c_rd_en, //input ceb MAP C

    output [7:0] map_a_din, //input din MAP A
    output [7:0] map_b_din, //input din MAP B
    output [7:0] map_c_din, //input din MAP C

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
    output [12:0] conv_addr    

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

        case (conv_layer_sel)

            2'b00: begin //96x96 -> 48x48x8

                frame = 48; 
                num_filters = 8; 
                in_width = 96;
                num_channels = 1;

                map_rd_en = resize_rd_en; //96x96   rd
                map_a_wr_en = map_wr_en;  //48x48x8 wr
                map_din   = resize_dout;  //96x96 -> 
                map_a_din = map_dout;     //-> 48x48

                conv_layer_base = 0;
                channels_per_filter = 1;

            end

            2'b01: begin //48x48x8 -> 24x24x16
    
                frame = 24; 
                num_filters = 16; 
                in_width = 48;
                num_channels = 8;

                map_rd_en = map_a_rd_en;
                map_b_wr_en = map_wr_en;
                map_din   = map_a_dout;  
                map_b_din = map_dout; 

                conv_layer_base = 72;
                channels_per_filter = 8;
            
            end
                    
            2'b10: begin //24x24x16 -> 12x12x32

                frame = 12; 
                num_filters = 32; 
                in_width = 24;
                num_channels = 16;

                map_rd_en = map_b_rd_en;
                map_c_wr_en = map_wr_en;
                map_din   = map_b_dout;  
                map_c_din = map_dout; 

                conv_layer_base = 1224;
                channels_per_filter = 16;

            end 

            default: begin

                frame = 0; 
                num_filters = 0;
                in_width = 0;

                resize_rd_en = 0; 
                map_wr_en = 0; 
                map_din = 0; 
                map_dout = 0;

                conv_layer_base = 0;
                channels_per_filter = 0;

                // etc for map_b/map_c signals too

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

            acc_in_en <= 0;

            pool_result <= 0;
            pixel_data_out <= 0;
            
        end else begin

            case(state)

                //compare out_x with frame for looping

                FSM_IDLE: begin

                    if (conv_en == 1'b1) begin
                        
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


                    //skip the first cycle at mac_index = 0 to avoid getting
                    //garbage data

                    //the same applies for getting weight data, calculate the
                    //addr location outside the FSM and populate mac_weight[]
    
                    if (mac_index > 0) begin 

                        mac_pixel_data[mac_index - 1] <= map_din;
                        mac_weight[mac_index - 1] <= weight_data;

                    end

                    if (mac_index < 9) begin

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
                    result[0] <= result[0] < 32'd0 ? 32'd0 : result[0];
                    result[1] <= result[1] < 32'd0 ? 32'd0 : result[1];
                    result[2] <= result[2] < 32'd0 ? 32'd0 : result[2];
                    result[3] <= result[3] < 32'd0 ? 32'd0 : result[3];
                    
                    state <= FSM_POOL;

                end

                //============================================
                //
                //============================================
                FSM_POOL: begin
                    
                    //maxpool the 4 results 
                    //[ 3  7 ]
                    //[ 1  5 ]  →  7

                    pool_result <= result[0];

                    if(result[1] > pool_result) pool_result <= result[1];
                    if(result[2] > pool_result) pool_result <= result[2];
                    if(result[3] > pool_result) pool_result <= result[3];
                    
                    state <= FSM_BOUND;

                end

                //============================================
                //Saturate or truncate pool_result to ensure its within 8 bits
                //============================================
                FSM_BOUND: begin
                    
                    if(pool_result > 127) begin

                        pixel_data_out <= 127;

                    end else if(pool_result < -128) begin

                        pixel_data_out <= -128;

                    end else begin

                        pixel_data_out <= pool_result[7:0];

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
reg acc_out_en;

reg signed [71:0] pixel_bus;
reg signed [71:0] weight_bus;

reg signed [7:0] mac_pixel_data  [0:8];
reg signed [7:0] mac_weight [0:8];

//temp accumulate variable so result[pool_index] doesn't get overwritten
//when looping over channels
reg signed [31:0] acc_temp;

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