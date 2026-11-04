# Tang Nano 20K timing constraints.
#
# The 27 MHz crystal feeds two PLLs: the system clock (sys_pll, the ratio must
# match top_tang20k.v's SYS_* parameters) and the video clocks. The derived
# clocks must be declared -- left implicit, the tools warn that the divider
# output "was determined to be a clock but was not created" and analyse it
# against a default.
#
# The system and pixel domains meet only in video.v, through its dual-clock
# line buffer, toggle synchronisers, and registers software changes only in
# blanking (palette, mode), and through the pixel reset's synchroniser: they
# are asynchronous to each other.
#
# Note: SDC here does not accept backslash line continuations.
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]
create_generated_clock -name clk_pix5 -source [get_ports {clk}] -master_clock clk -multiply_by 14 -divide_by 3 [get_pins {u_vpll/u_pll/CLKOUT}]
# CLKOUTP (clk_ser in the RTL) is CLKOUT again, in phase, on an output of its
# own for the HDMI serializers (video_pll.v). Everything clocked by it (the
# serializers and their reset's register) is same-clock; the spacing of the
# divider's output against it at the OSER10 is not something STA checks.
create_generated_clock -name clk_pix5p -source [get_ports {clk}] -master_clock clk -phase 0 -multiply_by 14 -divide_by 3 [get_pins {u_vpll/u_pll/CLKOUTP}]
create_generated_clock -name clk_pix -source [get_pins {u_vpll/u_pll/CLKOUT}] -master_clock clk_pix5 -divide_by 5 [get_pins {u_vpll/u_div/CLKOUT}]
create_generated_clock -name sys_clk -source [get_ports {clk}] -master_clock clk -multiply_by 3 -divide_by 2 [get_pins {u_spll/u_pll/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_pix clk_pix5 clk_pix5p}]
