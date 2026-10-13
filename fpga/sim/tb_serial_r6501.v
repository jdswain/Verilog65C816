`timescale 1ns/1ps
`default_nettype none
module tb_serial_r6501;
    localparam integer DIV = 8;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;

    reg [1:0] reg_sel = 0; reg [7:0] wdata = 0; wire [7:0] rdata;
    reg cs = 0, we = 0; reg rxd = 1; wire txd;

    serial_r6501 #(.DIVISOR(DIV)) dut (
        .clk(clk), .rst_n(rst_n), .reg_sel(reg_sel), .wdata(wdata),
        .rdata(rdata), .cs(cs), .we(we), .rxd(rxd), .txd(txd));

    integer errors = 0;
    task rd(input [1:0] r, output [7:0] v);
        begin
            @(negedge clk); reg_sel = r; we = 0; cs = 1;
            @(negedge clk); cs = 0;
            @(negedge clk); v = rdata;
        end
    endtask
    task wr(input [1:0] r, input [7:0] v);
        begin
            @(negedge clk); reg_sel = r; we = 1; wdata = v; cs = 1;
            @(negedge clk); cs = 0; we = 0;
        end
    endtask
    // send a byte into rxd at DIV cycles per bit
    task feed(input [7:0] b);
        integer i;
        begin
            rxd = 0; repeat (DIV) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rxd = b[i]; repeat (DIV) @(posedge clk);
            end
            rxd = 1; repeat (3*DIV) @(posedge clk);
        end
    endtask

    reg [7:0] v;
    integer i;
    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (4) @(posedge clk);

        // --- transmitter ready (bit 6) should be set when idle ---
        rd(2'd1, v);
        if (!v[6]) begin $display("FAIL: TX ready (bit 6) clear when idle: %02x", v); errors=errors+1; end
        if (v[0])  begin $display("FAIL: RX full (bit 0) set with no input: %02x", v); errors=errors+1; end

        // --- writing SRDR should transmit, clearing bit 6 while busy ---
        wr(2'd2, 8'h41);
        rd(2'd1, v);
        if (v[6]) begin $display("FAIL: TX ready still set while transmitting: %02x", v); errors=errors+1; end
        // wait for it to drain
        for (i = 0; i < 200 && v[6] == 0; i = i + 1) rd(2'd1, v);
        if (!v[6]) begin $display("FAIL: TX never became ready again"); errors=errors+1; end

        // --- receiver: feed a byte, bit 0 should set, SRDR should read it ---
        feed(8'h37);
        rd(2'd1, v);
        if (!v[0]) begin $display("FAIL: RX full (bit 0) not set after a byte: %02x", v); errors=errors+1; end
        rd(2'd2, v);
        if (v !== 8'h37) begin $display("FAIL: SRDR gave %02x, want 37", v); errors=errors+1; end
        rd(2'd1, v);
        if (v[0]) begin $display("FAIL: RX full still set after reading SRDR: %02x", v); errors=errors+1; end

        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end
    initial begin #500000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
