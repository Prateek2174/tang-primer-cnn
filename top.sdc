//Timing Constraints file
//
// cam_pclk period based on a direct measurement from the proven
// FinalVersionCapstone project: 25MHz cam_clk (XCLK) into the OV5640
// produces ~107MHz cam_pclk out. Our own cam_clk is 24MHz (close
// enough) and uses the SAME PLL multiply/divide register values
// (0x3036/0x3037) matched to that proven project, so ~107MHz is a
// reasonable estimate for our own cam_pclk too -- not yet independently
// re-measured on this exact board. cam_pclk was never previously
// constrained at all (no SDC existed), meaning dvp_capture.v and
// preprocessor.v -- both clocked by cam_pclk -- have never actually
// been timing-analyzed. If they're violating setup/hold at this speed,
// that would explain the garbled/noise-like captures seen throughout
// this session despite correct-looking RTL.

// SYS CLK 27MHz (board oscillator)
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]

// Camera pixel clock -- ~107MHz, per above
create_clock -name cam_pclk -period 9.346 -waveform {0 4.673} [get_ports {cam_pclk}]

// clk and cam_pclk are genuinely independent clock domains (board
// oscillator vs the camera's own internal PLL output) -- no fixed
// phase relationship between them.
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {cam_pclk}]
