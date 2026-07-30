module mac_array
(
    input rst_n,
    input clk,
    input reg [1:0] conv_layer_sel, //i need to know which conv layer im on
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

    output [14:0] addr_map_a, //output ada/adb MAP A 
    output [13:0] addr_map_b, //output ada/adb MAP B 
    output [12:0] addr_map_c, //output ada/adb MAP C

    //========================================================
    // WEIGHT_ROM
    //======================================================== 

    

);

//generic temp variables which will be assigned to the relevant BSRAM FEATURE
//MAP variables/wires based on the CONV layer we're on so multiple if 
//statements arent required in the FSM

wire       map_rd_en;
wire       map_wr_en;
wire [7:0] map_dout; //feature map output data
wire [7:0] map_din;  //feature map input data


reg signed [31:0] result [0:3];     //array of 4, 32 bit results from MAC
reg signed [31:0] maxpool_result;

reg signed [31:0] pool_result;

//looping counters

reg [5:0] out_x;        // output pixel x positions
reg [5:0] out_y;        // output pixel y positions
reg [5:0] filter_index; // filter index

//x and y coordinates for each of the 4 centered MAC
reg [5:0] x_pool;
reg [5:0] y_pool;
reg [1:0] pool_index;   // keeps count of the 0-3 (4) pool positions
reg [3:0] mac_index; //of the 9 MACs which one we're trying to get data for

//calls conv_acc.v as needed


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

//patch pixel (fr, fc):  addr = (oy + fr - 1) * 96 + (ox + fc - 1)
//                        where fr, fc ∈ {0, 1, 2}


//SDPB responds one cycle later (pipeline mode):
//  dout = pixel value at that address



    //========================================================
    // FSM states
    //========================================================    
      
    localparam FSM_IDLE  = 0;
//within conv it needs to do 
//
    localparam FSM_COORD = 1; //find the next 

//reg signed [7:0] mac_pixel [0:8];
//reg signed [7:0] mac_weight [0:8];

    localparam FSM_ADDR = 2;
    localparam FSM_MAC  = 3;
    localparam FSM_POOL  = 4;
    localparam FSM_WRITE = 5;
    localparam FSM_DONE  = 6;

    reg [3:0] state;

    //========================================================
    // Select CONV Layer Constants
    //======================================================== 

    reg [6:0] frame;
    reg [5:0] num_filters;

    always @(*) begin

        case (conv_layer_sel)

            2'b00: begin //96x96 -> 48x48x8

                frame = 48; 
                num_filters = 8; 

                assign map_rd_en = resize_rd_en; //96x96   rd
                assign map_wr_en = map_a_wr_en;  //48x48x8 wr
                assign map_din   = resize_dout;  //96x96 -> 
                assign map_dout  = map_a_din;    //-> 48x48

            end

            2'b01: begin //48x48x8 -> 24x24x16
    
                frame = 24; 
                num_filters = 16; 

                assign map_rd_en = map_a_rd_en;
                assign map_wr_en = map_b_wr_en;
                assign map_din   = map_a_dout;  
                assign map_dout  = map_b_din; 
            
            end
                    
            2'b10: begin //24x24x16 -> 12x12x32

                frame = 12; 
                num_filters = 32; 

                assign map_rd_en = map_b_rd_en;
                assign map_wr_en = map_c_wr_en;
                assign map_din   = map_b_dout;  
                assign map_dout  = map_c_din; 

            end 

        endcase

    end

    //========================================================
    // FEATURE MAP CONSTANTS
    //======================================================== 



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

            result[0] <= 0;
            result[1] <= 0;
            result[2] <= 0;
            result[3] <= 0;

            maxpool_result <= 0;
            
            conv_done <= 0;

            acc_in_en <= 0;

            pool_result <= 0;

            
        end else begin

            case(state)

                //compare out_x with frame for looping

                FSM_IDLE: begin

                    if (conv_en == 1'b1) begin
                        
                        state <= FSM_COORD;

                    end

                end

                FSM_COORD: begin

                    //there needs to be a counter since it needs to be 
                    //run 4 times append to result[] array

                    //go from out_x and out_y to address of the (2,2) data in
                    //BSRAM so i can access it. so 4 centered 3x3 patches

                    

                    if(pool_index == 3) 
                        pool_index <= 0;
                    else
                        pool_index <= pool_index + 1;

                    if() begin
                    
                        state <= FSM_RELU;

                    end

                end

                FSM_ADDR: begin

//reg signed [7:0] mac_pixel [0:8];
//reg signed [7:0] mac_weight [0:8];

//addr = y * 96 + x

// map_rd_en;
// map_wr_en;
// map_dout; //feature map output data
// map_din;  //feature map input data

                end

                FSM_MAC: begin

                // set acc_in_en to call conv_acc.v
                // wait for acc_out_en == 1'b1 before continuing
                

//if acc < 0: output = 0
//else:        output = acc

                    acc_in_en

                    // ReLU
                    result[0] = result[0] < 32'd0 ? 32'd0 : result[0];
                    result[1] = result[1] < 32'd0 ? 32'd0 : result[1];
                    result[2] = result[2] < 32'd0 ? 32'd0 : result[2];
                    result[3] = result[3] < 32'd0 ? 32'd0 : result[3];

                    if() begin
                    
                        state <= FSM_POOL;

                    end

                end

                FSM_POOL: begin
                    
                    //maxpool the 4 results 
                    //[ 3  7 ]
                    //[ 1  5 ]  →  7

                    pool_result <= result[0];

                    if(result[1] > pool_result) pool_result <= result[1];
                    if(result[2] > pool_result) pool_result <= result[2];
                    if(result[3] > pool_result) pool_result <= result[3];
                    
                    state <= FSM_WRITE;

                end

                FSM_WRITE: begin
                    
                    //write the result into BSRAM feature map
                    //addr = filter * (48*48) + oy * 48 + ox

                    map_wr_en <= 1'b1; //enable writing to BSRAM MAP
                    //calculate addr location
                    //access addr location

                end

                FSM_DONE: begin

                    //out_x vs frame
                    //out_y vs frame
                    //filter_index vs num_filters 

                    if (filter_index == num_filters - 1) begin

                        conv_done = 1'b1;
                        //

                    end else if (out_y == frame - 1) begin

                        out_y <= 0;
                        out_x <= 0;
                        filter_index <= filter_index + 1'b1;

                        state <= FSM_COORD;

                    end else if (out_x == frame - 1) begin

                        out_x <= 0;
                        out_y <= out_y + 1'b1;

                        state <= FSM_COORD;

                    end else begin

                        out_x <= out_x + 1'b1;

                        state <= FSM_COORD;

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

reg signed [7:0] mac_pixel  [0:8];
reg signed [7:0] mac_weight [0:8];

assign pixel_bus = {mac_pixel[0], mac_pixel[1], mac_pixel[2],
                    mac_pixel[3], mac_pixel[4], mac_pixel[5],
                    mac_pixel[6], mac_pixel[7], mac_pixel[8],};

assign weight_bus = {mac_weight[0], mac_weight[1], mac_weight[2],
                     mac_weight[3], mac_weight[4], mac_weight[5],
                     mac_weight[6], mac_weight[7], mac_weight[8],};

conv_acc #(.DATA_W(8), .ACC_W (32)) conv_core_acc (

    //IN

    .clk        (clk),
    .rst_n      (rst_n),
    .acc_in_en  (acc_in_en),
                
    .window_in  (pixel_bus),  //9 pixels for the 9 MACs
    .weight_in  (weight_bus), //9 weights from weight_rom.v

    //OUT

    .acc_out_en (acc_out_en), 
    .acc_out    (result[pool_index])
);  



endmodule