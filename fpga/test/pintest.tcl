set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
add_file -type verilog pintest.v
add_file -type cst pintest.cst
set_option -top_module pintest
set_option -verilog_std v2001
set_option -output_base_name pintest
run all
