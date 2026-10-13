set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
add_file -type verilog hdmitest.v
add_file -type verilog ../rtl/video_pll.v
add_file -type verilog ../rtl/video_timing.v
add_file -type verilog ../rtl/tmds_encoder.v
add_file -type verilog ../rtl/hdmi_out.v
add_file -type cst hdmitest.cst
set_option -top_module hdmitest
set_option -verilog_std v2001
set_option -output_base_name hdmitest
run all
