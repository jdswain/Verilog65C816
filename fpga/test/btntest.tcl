set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
add_file -type verilog btntest.v
add_file -type cst btntest.cst
set_option -top_module btntest
set_option -verilog_std v2001
set_option -output_base_name btntest
run all
