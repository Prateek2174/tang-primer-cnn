module weight_rom
(
    input clk,
    input rst_n,
    input [1:0] conv_layer_sel, // 00=CONV1, 01=CONV2, 10=CONV3, 11=FC
    input [12:0] conv_addr,     //conv address space (max 5831)
    input [7:0] fc_addr,        //separate addr for fc pROM (max 192)

    output [7:0] data_out


);

wire [7:0] conv_dout;
wire [7:0] fc_dout;

assign data_out = (conv_layer_sel == 2'b11) ? fc_dout : conv_dout;

    Gowin_pROM conv_prom(

        .dout(conv_dout), //output [7:0] dout
        .clk(clk), //input clk
        .oce(1'b1), //input oce
        .ce(1'b1), //input ce
        .reset(~rst_n), //input reset
        .ad(conv_addr) //input [12:0] ad

    );

    Gowin_pROM_fc fc_prom(

        .dout(fc_dout), //output [7:0] dout
        .clk(clk), //input clk
        .oce(1'b1), //input oce
        .ce(1'b1), //input ce
        .reset(~rst_n), //input reset
        .ad(fc_addr) //input [7:0] ad

    );

endmodule