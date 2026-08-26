//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//Tool Version: V1.9.11.03 Education
//Part Number: GW2A-LV18PG256C8/I7
//Device: GW2A-18
//Device Version: C
//Created Time: Mon Aug 24 16:11:58 2026

module Gowin_pROM_fc (dout, clk, oce, ce, reset, ad);

output [7:0] dout;
input clk;
input oce;
input ce;
input reset;
input [7:0] ad;

wire [23:0] prom_inst_0_dout_w;
wire gw_gnd;

assign gw_gnd = 1'b0;

pROM prom_inst_0 (
    .DO({prom_inst_0_dout_w[23:0],dout[7:0]}),
    .CLK(clk),
    .OCE(oce),
    .CE(ce),
    .RESET(reset),
    .AD({gw_gnd,gw_gnd,gw_gnd,ad[7:0],gw_gnd,gw_gnd,gw_gnd})
);

defparam prom_inst_0.READ_MODE = 1'b1;
defparam prom_inst_0.BIT_WIDTH = 8;
defparam prom_inst_0.RESET_MODE = "SYNC";
defparam prom_inst_0.INIT_RAM_00 = 256'hFAFC00FFFEFEFF04FDFE000202FEFFFD020101FF03020100FDFA020300FEFBFB;
defparam prom_inst_0.INIT_RAM_01 = 256'h030101FDFDFE01020300FE01FEFF00040301FFFDFB00FF00FDFF0104010401FF;
defparam prom_inst_0.INIT_RAM_02 = 256'h010400FFFAFD02030000FCFC020300FEFAFC0301FFFFFCFCFD00000203FFFFFD;
defparam prom_inst_0.INIT_RAM_03 = 256'hFCFA040101FDFDFEFD010000020300FFFF000104FDFE00000104FDFE00010300;
defparam prom_inst_0.INIT_RAM_04 = 256'hFE000003030401FEFAFEFEFE020301FD02FDFFFFFF04000301FFFCFB01010100;
defparam prom_inst_0.INIT_RAM_05 = 256'h030102FDFBFD03030100FBFC03FD00FEFF03FEFFFF0203FE03FEFFFEFF02FD01;

endmodule //Gowin_pROM_fc
