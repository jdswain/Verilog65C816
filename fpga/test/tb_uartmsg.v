`timescale 1ns/1ps
module tb_uartmsg;
  reg clk=0; always #18.5 clk=~clk;
  wire tx; wire [5:0] led;
  uartmsg dut(.clk(clk), .uart_tx(tx), .led(led));
  integer i; reg [7:0] ch; integer n=0;
  initial begin
    forever begin
      @(negedge tx);
      repeat (234+117) @(posedge clk);
      for (i=0;i<8;i=i+1) begin ch[i]=tx; repeat(234) @(posedge clk); end
      if (ch>=32 && ch<127) $write("%c", ch); else $write("[%02x]", ch);
      $fflush; n=n+1; if (n==34) begin $write("\n"); $finish; end
    end
  end
  initial begin #20000000; $display("\nno output"); $finish; end
endmodule
