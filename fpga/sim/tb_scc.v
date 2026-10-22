// tb_scc.v -- the emulated SCC against the init sequence MiniMon uses, with
// channel A's transmitter looped back to its receiver.
//
//   iverilog -g2005 -o scc_sim rtl/scc_85c30.v rtl/uart_tx.v rtl/uart_rx.v sim/tb_scc.v
//   vvp scc_sim
`timescale 1ns/1ps
`default_nettype none
module tb_scc;
    localparam integer DIV = 8;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;

    reg [1:0] addr = 0; reg [7:0] wdata = 0; wire [7:0] rdata;
    reg cs = 0, we = 0;
    wire int_n, txd;
    reg  loop = 1;                          // channel A looped back
    reg  rxd_drv = 1;
    wire rxd = loop ? txd : rxd_drv;

    scc_85c30 #(.DIVISOR(DIV)) dut (
        .clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata), .rdata(rdata),
        .cs(cs), .we(we), .int_n(int_n), .rxd(rxd), .txd(txd));

    localparam [1:0] BC = 2'd0, BD = 2'd1, AC = 2'd2, AD = 2'd3;

    integer errors = 0;
    integer n;
    task rd(input [1:0] r, output [7:0] v);
        begin
            @(negedge clk); addr = r; we = 0; cs = 1;
            @(negedge clk); cs = 0;
            v = rdata;
        end
    endtask
    task wr(input [1:0] r, input [7:0] v);
        begin
            @(negedge clk); addr = r; we = 1; wdata = v; cs = 1;
            @(negedge clk); cs = 0; we = 0;
        end
    endtask
    task wreg(input [1:0] port, input [3:0] n, input [7:0] v);
        begin
            wr(port, n[3] ? {5'b00001, n[2:0]} : {5'b0, n[2:0]});
            wr(port, v);
        end
    endtask
    task rreg(input [1:0] port, input [3:0] n, output [7:0] v);
        begin
            if (n != 0) wr(port, n[3] ? {5'b00001, n[2:0]} : {5'b0, n[2:0]});
            rd(port, v);
        end
    endtask
    task check(input [8*40-1:0] what, input [7:0] got, input [7:0] want);
        if (got !== want) begin
            $display("FAIL: %0s: got %02x, want %02x", what, got, want);
            errors = errors + 1;
        end
    endtask
    // wait for channel A to have a character, or give up
    task wait_rx(output ok);
        integer t; reg [7:0] s;
        begin
            ok = 0;
            for (t = 0; t < 400 && !ok; t = t + 1) begin
                rd(AC, s);
                if (s[0]) ok = 1;
            end
        end
    endtask

    reg [7:0] v;
    reg ok;
    integer i;
    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (4) @(posedge clk);

        // MiniMon's init: hardware reset, async x16 8N1, BRG, enable.
        wreg(AC, 9, 8'hC0);
        wreg(AC, 4, 8'h44);
        wreg(AC, 3, 8'hC0);
        wreg(AC, 5, 8'h60);
        wreg(AC, 11, 8'h50);
        wreg(AC, 12, 8'h00);
        wreg(AC, 13, 8'h00);
        wreg(AC, 14, 8'h01);
        wreg(AC, 3, 8'hC1);
        wreg(AC, 5, 8'hEA);

        // Pointer: point high, RR12/RR13 read back what was written.
        wreg(AC, 12, 8'h5A);
        rreg(AC, 12, v); check("RR12 readback", v, 8'h5A);
        wreg(BC, 13, 8'hA5);
        rreg(BC, 13, v); check("RR13 channel B", v, 8'hA5);
        rreg(AC, 13, v); check("RR13 channel A unchanged", v, 8'h00);
        rd(AC, v);       check("pointer back at RR0 (Tx empty)", v & 8'h05, 8'h04);

        // WR2 is shared: write via A, read via A unmodified.
        wreg(BC, 2, 8'h30);
        rreg(AC, 2, v);  check("WR2 shared", v, 8'h30);

        // One character round trip.
        rd(AC, v);  check("RR0 idle", v & 8'h05, 8'h04);
        // The first byte goes straight to the shift register; the second
        // waits in the buffer.
        wr(AD, 8'h41);
        wr(AD, 8'h40);
        rd(AC, v);  check("RR0 Tx buffer full", v & 8'h04, 8'h00);
        rreg(AC, 1, v); check("RR1 not all sent", v & 8'h01, 8'h00);
        wait_rx(ok);
        if (!ok) begin $display("FAIL: no character came back"); errors = errors + 1; end
        rd(AD, v);  check("received data", v, 8'h41);
        wait_rx(ok);
        rd(AD, v);  check("second byte", v, 8'h40);
        rd(AC, v);  check("RR0 after read", v & 8'h01, 8'h00);
        rreg(AC, 1, v); check("RR1 all sent", v & 8'h21, 8'h01);

        // RR8 through the control port.
        wr(AD, 8'h42);
        wait_rx(ok);
        rreg(AC, 8, v); check("RR8 via control port", v, 8'h42);

        // Fill the FIFO: three held, the fourth overruns.
        for (i = 0; i < 4; i = i + 1) begin
            wr(AD, 8'h61 + i);
            repeat (12*DIV) @(posedge clk);
        end
        repeat (12*DIV) @(posedge clk);
        rreg(AC, 1, v); check("RR1 overrun", v & 8'h20, 8'h20);
        rd(AD, v); check("FIFO 0", v, 8'h61);
        rd(AD, v); check("FIFO 1", v, 8'h62);
        rd(AD, v); check("FIFO 2", v, 8'h63);
        rd(AC, v); check("FIFO empty", v & 8'h01, 8'h00);
        wr(AC, 8'h30);                       // error reset
        rreg(AC, 1, v); check("overrun cleared", v & 8'h20, 8'h00);

        // Receive interrupt.
        if (!int_n) begin $display("FAIL: interrupt before MIE"); errors = errors + 1; end
        wreg(AC, 1, 8'h10);                  // Rx int on all characters
        wreg(AC, 9, 8'h08);                  // MIE
        wr(AD, 8'h55);
        wait_rx(ok);
        if (int_n) begin $display("FAIL: no Rx interrupt"); errors = errors + 1; end
        rreg(AC, 3, v); check("RR3 A Rx pending", v, 8'h20);
        wreg(BC, 9, 8'h09);                  // MIE, VIS, status low
        rreg(BC, 2, v); check("RR2 B vector, A Rx", v, 8'h3C);
        rd(AD, v);  check("Rx int data", v, 8'h55);
        if (!int_n) begin $display("FAIL: Rx interrupt stuck"); errors = errors + 1; end

        // Transmit interrupt: pending when the buffer empties, cleared by
        // WR0 Reset Tx Int Pending.
        wreg(AC, 1, 8'h02);
        wr(AD, 8'h01);
        repeat (4) @(posedge clk);
        if (int_n) begin $display("FAIL: no Tx interrupt"); errors = errors + 1; end
        rreg(AC, 3, v); check("RR3 A Tx pending", v, 8'h10);
        wr(AC, 8'h28);
        if (!int_n) begin $display("FAIL: Tx interrupt not reset"); errors = errors + 1; end
        repeat (14*DIV) @(posedge clk);
        rd(AD, v);                           // drain the looped-back byte

        // Channel B: transmit goes nowhere, nothing received.
        wr(BD, 8'h99);
        rd(BC, v);  check("RR0 B", v & 8'h05, 8'h04);

        // Receiver disabled: characters are dropped.
        wreg(AC, 1, 8'h00);
        wreg(AC, 3, 8'hC0);
        wr(AD, 8'h77);
        repeat (14*DIV) @(posedge clk);
        rd(AC, v);  check("Rx disabled", v & 8'h01, 8'h00);

        // Channel B's baud-rate generator: a zero count every TC + 2
        // clocks, the external/status interrupt once WR15 bit 1 and WR1
        // bit 0 allow it, until WR0 Reset Ext/Status Interrupts.
        wreg(BC, 12, 8'd10); wreg(BC, 13, 8'd0);
        wreg(BC, 15, 8'h02);                 // zero count IE
        wreg(BC, 14, 8'h03);                 // PCLK, enabled
        repeat (40) @(posedge clk);
        if (!int_n) begin $display("FAIL: zero count interrupt without WR1 bit 0"); errors = errors + 1; end
        wreg(BC, 1, 8'h01);                  // external/status interrupts
        repeat (14) @(posedge clk);
        if (int_n) begin $display("FAIL: no zero count interrupt"); errors = errors + 1; end
        rreg(AC, 3, v); check("RR3 B Ext/Status pending", v, 8'h01);
        rreg(BC, 2, v); check("RR2 B vector, B Ext/Status", v, 8'h32);
        wr(BC, 8'h10);                       // reset ext/status interrupts
        if (!int_n) begin $display("FAIL: zero count interrupt not reset"); errors = errors + 1; end
        @(posedge clk);
        while (!(dut.brg[0] == 16'd0 && !dut.brg_reload[0])) @(posedge clk);
        @(posedge clk); n = 1;
        while (!(dut.brg[0] == 16'd0 && !dut.brg_reload[0])) begin @(posedge clk); n = n + 1; end
        check("zero count period", n, 8'd12);
        wreg(BC, 14, 8'h02);                 // stopped
        wr(BC, 8'h10);
        repeat (40) @(posedge clk);
        if (!int_n) begin $display("FAIL: zero count after stopping"); errors = errors + 1; end
        wreg(BC, 1, 8'h00);

        // Hardware reset clears MIE and the enables.
        wreg(AC, 9, 8'hC0);
        rreg(AC, 3, v); check("RR3 after reset", v, 8'h00);
        if (!int_n) begin $display("FAIL: interrupt after reset"); errors = errors + 1; end

        if (errors == 0) $display("PASS");
        else             $display("%0d errors", errors);
        $finish;
    end
endmodule

`default_nettype wire
