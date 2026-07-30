//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW2A-LV18PG256C8/I7
//Device: GW2A-18
//Device Version: C
//Created Time: Sun Jul 26 22:30:41 2026

module Gowin_pROM (dout, clk, oce, ce, reset, ad);

output [7:0] dout;
input clk;
input oce;
input ce;
input reset;
input [12:0] ad;

wire lut_f_0;
wire lut_f_1;
wire [27:0] prom_inst_0_dout_w;
wire [3:0] prom_inst_0_dout;
wire [27:0] prom_inst_1_dout_w;
wire [7:4] prom_inst_1_dout;
wire [23:0] prom_inst_2_dout_w;
wire [7:0] prom_inst_2_dout;
wire dff_q_0;
wire dff_q_1;
wire gw_gnd;

assign gw_gnd = 1'b0;

LUT2 lut_inst_0 (
  .F(lut_f_0),
  .I0(ce),
  .I1(ad[12])
);
defparam lut_inst_0.INIT = 4'h2;
LUT3 lut_inst_1 (
  .F(lut_f_1),
  .I0(ce),
  .I1(ad[11]),
  .I2(ad[12])
);
defparam lut_inst_1.INIT = 8'h20;
pROM prom_inst_0 (
    .DO({prom_inst_0_dout_w[27:0],prom_inst_0_dout[3:0]}),
    .CLK(clk),
    .OCE(oce),
    .CE(lut_f_0),
    .RESET(reset),
    .AD({ad[11:0],gw_gnd,gw_gnd})
);

defparam prom_inst_0.READ_MODE = 1'b1;
defparam prom_inst_0.BIT_WIDTH = 4;
defparam prom_inst_0.RESET_MODE = "SYNC";

pROM prom_inst_1 (
    .DO({prom_inst_1_dout_w[27:0],prom_inst_1_dout[7:4]}),
    .CLK(clk),
    .OCE(oce),
    .CE(lut_f_0),
    .RESET(reset),
    .AD({ad[11:0],gw_gnd,gw_gnd})
);

defparam prom_inst_1.READ_MODE = 1'b1;
defparam prom_inst_1.BIT_WIDTH = 4;
defparam prom_inst_1.RESET_MODE = "SYNC";

pROM prom_inst_2 (
    .DO({prom_inst_2_dout_w[23:0],prom_inst_2_dout[7:0]}),
    .CLK(clk),
    .OCE(oce),
    .CE(lut_f_1),
    .RESET(reset),
    .AD({ad[10:0],gw_gnd,gw_gnd,gw_gnd})
);

defparam prom_inst_2.READ_MODE = 1'b1;
defparam prom_inst_2.BIT_WIDTH = 8;
defparam prom_inst_2.RESET_MODE = "SYNC";

DFFE dff_inst_0 (
  .Q(dff_q_0),
  .D(ad[12]),
  .CLK(clk),
  .CE(ce)
);
DFFE dff_inst_1 (
  .Q(dff_q_1),
  .D(dff_q_0),
  .CLK(clk),
  .CE(oce)
);
MUX2 mux_inst_2 (
  .O(dout[0]),
  .I0(prom_inst_0_dout[0]),
  .I1(prom_inst_2_dout[0]),
  .S0(dff_q_1)
);
MUX2 mux_inst_5 (
  .O(dout[1]),
  .I0(prom_inst_0_dout[1]),
  .I1(prom_inst_2_dout[1]),
  .S0(dff_q_1)
);
MUX2 mux_inst_8 (
  .O(dout[2]),
  .I0(prom_inst_0_dout[2]),
  .I1(prom_inst_2_dout[2]),
  .S0(dff_q_1)
);
MUX2 mux_inst_11 (
  .O(dout[3]),
  .I0(prom_inst_0_dout[3]),
  .I1(prom_inst_2_dout[3]),
  .S0(dff_q_1)
);
MUX2 mux_inst_14 (
  .O(dout[4]),
  .I0(prom_inst_1_dout[4]),
  .I1(prom_inst_2_dout[4]),
  .S0(dff_q_1)
);
MUX2 mux_inst_17 (
  .O(dout[5]),
  .I0(prom_inst_1_dout[5]),
  .I1(prom_inst_2_dout[5]),
  .S0(dff_q_1)
);
MUX2 mux_inst_20 (
  .O(dout[6]),
  .I0(prom_inst_1_dout[6]),
  .I1(prom_inst_2_dout[6]),
  .S0(dff_q_1)
);
MUX2 mux_inst_23 (
  .O(dout[7]),
  .I0(prom_inst_1_dout[7]),
  .I1(prom_inst_2_dout[7]),
  .S0(dff_q_1)
);
endmodule //Gowin_pROM
