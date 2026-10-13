set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
add_file -type verilog uartmsg.v
add_file -type verilog ../rtl/uart_tx.v
add_file -type cst uartmsg.cst
set_option -top_module uartmsg
set_option -verilog_std v2001
set_option -output_base_name uartmsg
run all
