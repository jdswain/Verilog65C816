`timescale 1ns/1ps
module tb_uarttest;
  reg clk = 0; always #18.5 clk = ~clk;      // ~27 MHz
  wire tx; wire [5:0] led;
  uarttest dut(.clk(clk), .uart_tx(tx), .led(led));
  integer i; reg [7:0] ch; integer n = 0;
  initial begin
    forever begin
      @(negedge tx);
      repeat (234 + 117) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin ch[i] = tx; repeat (234) @(posedge clk); end
      n = n + 1;
      if (n <= 5) $display("char %0d = %02x", n, ch);
      if (n == 5) $finish;
    end
  end
  initial begin #5000000; $display("no characters seen (busy=%b led=%b)", dut.busy, led); $finish; end
endmodule
