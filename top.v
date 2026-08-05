module top
(
    input wire clk,
    input wire rst_n, //Active low
    output led_1,     // DONE LED
    output led_2,     // READY LED
  
    //========================================================
    // OV5640
    //======================================================== 

    inout wire cam_scl,  //I2C clock to camera this is also Dislpay 2
    inout wire cam_sda,  //I2C data to camera this is also Dislpay 2

    input cam_vsync,     //cam vsync
	input cam_href,      //cam hsync refrence, data valid
	input cam_pclk,      //cam pixel clock
    
    output cam_xclk,     //clock to camera 
	
    input[7:0] cam_data, //camera data
	
    output cam_rst_n,    //camera reset 
	output cam_pwdn,     //camera power down

	output wire [7:0] y_data,            
	output wire [7:0] cbcr_data,

);

reg [7:0] y_fifo;
reg [7:0] cbcr_fifo;

wire cam_clk;

wire [7:0] y_temp;
wire [7:0] cbcr_temp;
wire [10:0] h_count;
wire [10:0]  v_count;

Gowin_PLL pll_instance(
        .clkin(clk), //input  clkin
        .clkout0(cam_clk), //output  clkout0 25
        .clkout1(), //output  clkout1 35
        .clkout2(), //output  clkout2 150
        .clkout3(), //output  clkout3 75
        .clkout4(), //output  clkout4 !75
        .mdclk() //input  mdclk
);


wire [9:0]  lut_index;
wire [31:0] lut_data;

wire [3:0]  lut_lcd_index;
wire [23:0] lut_lcd_data;

wire [15:0] out_data;

wire cam_16bit_wr_en;
wire read_enable;

wire [15:0] fifo_data_out;

wire trigger_1;
wire phase_1_done;

assign cam_xclk = cam_xvclk;
wire cam_xvclk;

//========================================================
// OV5640 -> DVP_CAPTURE
//======================================================== 

i2c_bitbang_cam i2c_cam(

    //IN

    .clk     (clk),
    .rst_n   (rst_n),
    .cam_done(phase_1_done),
    .cam_clk (cam_clk), 

    //OUT

    .busy (),
    .done (),
    
//    .led_1 (led_1),
    .sda_1 (cam_sda),
    .scl_1 (cam_scl),

    .cam_pwdn(cam_pwdn),
    .cam_rst_n(cam_rst_n),
    .cam_xvclk(cam_xvclk)
);

//camera bytes are separated into y_data and y_data and cbcr_data
dvp_capture dvp_capture_1(
    
    //IN

    .rst_n      (rst_n),
	.pclk       (cam_pclk),
	.input_data (cam_data),
	.de_i       (cam_href),

    //OUT

	.y_data     (y_temp),
	.cbcr_data  (cbcr_temp),

//    .out_data   (out_data),
    .hblank     (),
	.de_o       (cam_16bit_wr_en)
);

//========================================================
// DVP_CAPTURE -> PREPROCESSOR
//======================================================== 

preprocessor preprocessor_1(

//resize -> 96x96
//normalize int8

    //IN

    .rst_n           (rst_n),
    .pclk            (cam_pclk),
    .href            (cam_href),
    .vsync           (cam_vsync),
    .y_data          (y_temp),
    .data_en         (cam_16bit_wr_en),

    .row_count       (),
    .col_count       (),

    //OUT

    .resize_en       (resize_en),
    .y_resize        (y_resize) //[7:0]

);

//========================================================
// PREPROCESSOR -> 96x96 BSRAM
//======================================================== 

wire [7:0] y_resize;
wire       resize_en;

wire [7:0] resize_dout;  //input -> dout 96x96
wire [13:0] resize_addr; //output -> adb 96x96
wire resize_rd_en;       //output -> ceb 96x96

    Gowin_SDPB resized_frame(

        .clka(cam_pclk),     //input clka
        .din(y_resize),       //input [7:0] din
        .ada(ada),       //input [13:0] ada
        .cea(resize_en),       //input cea
        .reseta(~rst_n), //input reseta

        .clkb(cam_pclk),     //input clkb
        .ceb(resize_rd_en),       //input ceb
        .resetb(~rst_n), //input resetb
        .oce(1'b1),       //input oce
        .adb(resize_addr),        //input [13:0] adb

        .dout(resize_dout), //output [7:0] dout
    );

//========================================================
// CNN 
//======================================================== 

wire conv_en;
wire conv_done;
wire [1:0] conv_layer_sel;

cnn_top cnn_top_1(

    //IN

    .rst_n     (rst_n),
    .pclk      (cam_pclk), 
    .vsync     (cam_vsync),

    .conv_done (conv_done),
    .pool_done (),
    .gap_done  (),
    .fc_done   (),
    .uart_done (),

    //OUT

    .conv_en   (conv_en),
    .pool_en   (),
    .gap_en    (), 
    .fc_en     (), 
    .uart_en   (), 

    .conv_layer_sel (conv_layer_sel) //[1:0] tie to weight_rom.v to find out the layer

);

mac_array mac_array_1(

    //IN

    .rst_n          (rst_n),
    .clk            (cam_pclk),
    .conv_layer_sel (conv_layer_sel),  //[1:0]

    .conv_en        (conv_en), //stay in idle till this is set
    
    //OUT

    .conv_done      (conv_done), //flag for when the conv layer is completed

    //========================================================
    // 96x96 BSRAM
    //======================================================== 
    
    .resize_dout  (resize_dout), //input -> dout 96x96 [7:0]
    .resize_addr  (resize_addr), //output -> adb 96x96 [13:0]
    .resize_rd_en (resize_rd_en), //output -> ceb 96x96

    //========================================================
    // FEATURE MAP BSRAM MAPPING
    //======================================================== 

    .map_a_wr_en (cea_a), //output -> cea MAP A
    .map_b_wr_en (cea_b), //output -> cea MAP B
    .map_c_wr_en (cea_c), //output -> cea MAP C

    .map_a_rd_en (ceb_a), //output ->  ceb MAP A
    .map_b_rd_en (ceb_b), //output ->  ceb MAP B
    .map_c_rd_en (ceb_c), //output ->  ceb MAP C

    .map_a_din (din_map_a), //output ->  din MAP A [7:0]
    .map_b_din (din_map_b), //output ->  din MAP B [7:0]
    .map_c_din (din_map_c), //output ->  din MAP C [7:0]

    .map_a_dout (dout_map_a), //input -> dout MAP A [7:0] 
    .map_b_dout (dout_map_b), //input -> dout MAP B [7:0]
    .map_c_dout (dout_map_c), //input -> dout MAP C [7:0]

    .map_a_wr_addr (addr_map_a_ada), //output -> ada MAP A [14:0]
    .map_b_wr_addr (addr_map_b_ada), //output -> ada MAP B [13:0]
    .map_c_wr_addr (addr_map_c_ada), //output -> ada MAP C [12:0]

    .map_a_rd_addr (addr_map_a_adb), //output -> adb MAP A [14:0]
    .map_b_rd_addr (addr_map_b_adb), //output -> adb MAP B [13:0]
    .map_c_rd_addr (addr_map_c_adb), //output -> adb MAP C [12:0]

    //========================================================
    // WEIGHT_ROM
    //======================================================== 

    .weight_data (weight_data), //[7:0] 
    .conv_addr   (conv_addr) //[12:0] 

);

global_avg_pool avg_pool(

    .rst_n (rst_n),
    .clk (cam_pclk),

    .gap_en (),       // start signal from cnn_top IN
    .gap_done (), // done signal to cnn_top OUT

    //========================================================
    // FEATURE MAP C BSRAM (12x12x32)
    //========================================================

    .map_c_dout (),      // input <- dout MAP C [7:0]
    .map_c_rd_addr (),  // output -> adb MAP C [12:0]
    .map_c_rd_en (),       // output -> ceb MAP C

    //========================================================
    // READ INTERFACE -> classifier.v
    //========================================================

    .gap_addr (),   // IN [4:0]
    .gap_data ()   // OUT [7:0]

);

classifier fc_layer(

    .rst_n  (),
    .clk    (),

    .fc_en  (),        // start signal from cnn_top
    .fc_done(),  // done signal to cnn_top

    //========================================================
    // GLOBAL_AVG_POOL READ INTERFACE
    //========================================================

    .gap_addr (),  // request channel 0-31 [4:0] OUT
    .gap_data (),  // averaged value for that channel IN

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

//========================================================
// WEIGHTS
//======================================================== 

wire [7:0] weight_data;
wire [12:0] conv_addr; //tie with mac_array.v
wire [7:0] fc_addr;    //tie with classifier.v 


weight_rom weights(

    //IN

    .clk            (cam_pclk),
    .rst_n          (rst_n),
    .conv_layer_sel (conv_layer_sel), //[1:0] 00=CONV1, 01=CONV2, 10=CONV3, 11=FC
    .conv_addr      (conv_addr),      //[12:0] conv address space (max 5831)
    .fc_addr        (),               //[7:0] separate addr for fc pROM (max 192)

    //OUT

    .data_out       (weight_data) //[7:0]
);

//========================================================
// FEATURE MAPS
//======================================================== 

wire cea_a;
wire cea_b;
wire cea_c;

wire ceb_a;
wire ceb_b;
wire ceb_c;

wire [7:0] din_map_a;
wire [7:0] din_map_b;
wire [7:0] din_map_c;

wire [7:0] dout_map_a;
wire [7:0] dout_map_b;
wire [7:0] dout_map_c;

wire [14:0] addr_map_a_ada;
wire [13:0] addr_map_b_ada;
wire [12:0] addr_map_c_ada;

wire [14:0] addr_map_a_adb;
wire [13:0] addr_map_b_adb;
wire [12:0] addr_map_c_adb;

    //Feature map A — 48×48×8  = 18,432 bytes  (output of Conv1+ReLU+Pool)

    Gowin_SDPB_A feature_map_a(
        .dout(dout_map_a), //output [7:0] dout
        .clka(cam_pclk),   //input clka
        .cea(cea_a),       //input cea
        .reseta(~rst_n),   //input reseta
        .clkb(cam_pclk),   //input clkb
        .ceb(ceb_a),       //input ceb
        .resetb(~rst_n),   //input resetb
        .oce(1'b1),        //input oce
        .ada(addr_map_a_ada),  //input [14:0] ada MAP A
        .din(din_map_a),   //input [7:0] din
        .adb(addr_map_a_adb)   //input [14:0] adb
    );

    //Feature map B — 24×24×16 =  9,216 bytes  (output of Conv2+ReLU+Pool)

    Gowin_SDPB_B feature_map_b(
        .dout(dout_map_b), //output [7:0] dout
        .clka(cam_pclk),   //input clka
        .cea(cea_b),       //input cea
        .reseta(~rst_n),   //input reseta
        .clkb(cam_pclk),   //input clkb
        .ceb(ceb_b),       //input ceb
        .resetb(~rst_n),   //input resetb
        .oce(1'b1),        //input oce
        .ada(addr_map_b_ada),  //input [13:0] ada MAP B
        .din(din_map_b),   //input [7:0] din
        .adb(addr_map_b_adb)   //input [13:0] adb
    );

    //Feature map C — 12×12×32 =  4,608 bytes  (output of Conv3+ReLU+Pool)

    Gowin_SDPB_C feature_map_c(
        .dout(dout_map_c), //output [7:0] dout
        .clka(cam_pclk),   //input clka
        .cea(cea_c),       //input cea
        .reseta(~rst_n),   //input reseta
        .clkb(cam_pclk),   //input clkb
        .ceb(ceb_c),       //input ceb
        .resetb(~rst_n),   //input resetb
        .oce(1'b1),        //input oce
        .ada(addr_map_c_ada),  //input [12:0] ada MAP C
        .din(din_map_c),   //input [7:0] din
        .adb(addr_map_c_adb)   //input [12:0] adb
    );

// ================================================================
// Line buffer from capture clock domain to display clock domain
// ================================================================

wire [15:0] buf_pixel;
wire        buf_valid;
wire        read_enable;
wire [10:0] h_count;
wire [10:0] v_count;

cam_line_buffer_30rows #(
    .WIDTH (640),
    .ROWS  (50)
) cam_buf (
    .wr_clk          (cam_pclk),
    .rst_n           (rst_n),
    .cam_vsync       (cam_vsync),
    .cam_16bit_wr_en (cam_16bit_wr_en),
    .cam_pixel_in    ({cbcr_temp, y_temp}),
    .rd_clk          (display_clk),
    .rd_en           (read_enable),
    .rd_x            (h_count),
    .rd_y            (v_count),
    .rd_pixel_out    (buf_pixel),
    .rd_valid        (buf_valid)
);

// ================================================================
// UART 20K -> PC
// ================================================================

uart uart_tx(

    //IN

    .clk             (),
    .rst_n           (rst_n),
    .tx_data         (), //[7:0]
    .tx_data_valid   (),

    //OUT

    .tx_data_ready   (), //data is ready to send
    .tx_pin          (), //serial data output 
    .tx_busy         ()
);


//always @(negedge lcd_dclk) begin
//    if ((h_count < 400) && (v_count < 240)) begin
//        y_fifo <= 8'hFF;
//        cbcr_fifo <= 8'h80;
//    end else if ((h_count >=400) && (v_count < 240)) begin
//        y_fifo <= 8'h80;
//        cbcr_fifo <= 8'hFF;
//    end else if ((h_count < 400) && (v_count >= 240)) begin
//        y_fifo <= 8'h80;
//        cbcr_fifo <= 8'hFF;
//    end else begin
//        y_fifo <= 8'hFF;
//        cbcr_fifo <= 8'h80;
//    end

//    if (h_count < 400) begin
//        y_fifo <= 8'hFF;
//        cbcr_fifo <= 8'h80;
//    end else begin
//        y_fifo <= 8'h80;
//        cbcr_fifo <= 8'hFF;
//    end
//end


endmodule