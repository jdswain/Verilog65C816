`timescale 1ns/1ps
module tb_socdbg;
  reg clk=0; always #18.5 clk=~clk;
  wire tx; wire [5:0] led;
  socdbg dut(.clk(clk), .uart_tx(tx), .led(led));
  integer i; reg [7:0] ch; integer n=0;
  initial begin
    forever begin
      @(negedge tx);
      repeat (234+117) @(posedge clk);
      for (i=0;i<8;i=i+1) begin ch[i]=tx; repeat(234) @(posedge clk); end
      if (ch>=32 && ch<127) $write("%c", ch); else if (ch==13) ; else if (ch==10) $write("\n");
      $fflush; n=n+1; if (n==30) $finish;
    end
  end
  initial begin #400000000; $display("\n(timeout)"); $finish; end
endmodule
