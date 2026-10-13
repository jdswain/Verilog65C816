set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
add_file -type verilog socdbg.v
add_file -type verilog ../../cpu_65c816.v
foreach f [lsort [glob ../rtl/*.v]] { add_file -type verilog $f }




add_file -type cst uartmsg.cst
set_option -include_path [file join [pwd] ../rtl]
set_option -top_module socdbg
set_option -verilog_std v2001
set_option -output_base_name socdbg
run all
