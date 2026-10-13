# Tang Nano 20K timing constraints.
#
# The 27 MHz crystal only feeds the PLL. The SoC and the video output both run
# from the PLL's 25.2 MHz output, so the derived clocks must be declared -- left
# implicit, the tools warn that the divider output "was determined to be a clock
# but was not created" and analyse it against a default.
#
# Note: SDC here does not accept backslash line continuations.
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]
create_generated_clock -name clk_pix5 -source [get_ports {clk}] -master_clock clk -multiply_by 14 -divide_by 3 [get_pins {u_vpll/u_pll/CLKOUT}]
create_generated_clock -name clk_pix -source [get_pins {u_vpll/u_pll/CLKOUT}] -master_clock clk_pix5 -divide_by 5 [get_pins {u_vpll/u_div/CLKOUT}]
