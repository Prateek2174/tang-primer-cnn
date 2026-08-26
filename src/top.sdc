// Tang Primer 20K onboard oscillator: 27MHz, fed directly into clk (H11,
// LVCMOS25, see top.cst) with no PLL. Period = 1000/27 = 37.037ns.
create_clock -name clk -period 37.037 [get_ports {clk}]
