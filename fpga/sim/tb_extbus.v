// tb_extbus.v -- external_bus.v against a stub card in both bus styles.
`timescale 1ns/1ps
`default_nettype none

module tb_extbus;
    // 25.2 MHz / 1 MHz would be 12.6 clocks per half-cycle; the divider needs
    // an integer, so the sim uses 24 MHz to keep PHI0 exactly 1 MHz.
    localparam integer CLK_HZ = 24_000_000;

    reg clk = 0, rst_n = 0;
    always #(500.0/24.0) clk = ~clk;

    reg style = 0;
    integer errors = 0;
    task check(input [127:0] name, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %h expected %h", name, got, exp);
            errors = errors + 1;
        end else $display("  ok  %0s = %h", name, got);
    endtask

    //------------------------------------------------------------------
    // A minimal card: 16 registers, selected by sel_n, latched on the
    // trailing edge of whichever write strobe the style uses.
    //------------------------------------------------------------------
    reg [7:0] card [0:15];
    integer i;

    // --- style 0 instance ---
    wire [3:0] a0; wire [7:0] do0; wire oe0; wire [3:0] s0;
    wire rw0, phi0_0, res0;
    reg  [7:0] di0;
    reg [10:0] addr; reg [7:0] wdata; reg req, we;
    wire [7:0] rdata0; wire ack0;

    external_bus #(.CLK_HZ(CLK_HZ), .PHI0_HZ(1_000_000), .STYLE(0)) u0 (
        .clk(clk), .rst_n(rst_n),
        .addr(addr), .wdata(wdata), .rdata(rdata0),
        .req(req & ~style), .we(we), .ack(ack0),
        .card_reset(1'b0), .irq(),
        .ext_a(a0), .ext_d_in(di0), .ext_d_out(do0), .ext_d_oe(oe0),
        .ext_sel_n(s0), .ext_rw(rw0), .ext_phi0(phi0_0),
        .ext_res_n(res0), .ext_irq_n(1'b1)
    );

    // --- style 1 instance ---
    wire [3:0] a1; wire [7:0] do1; wire oe1; wire [3:0] s1;
    wire wr_n, rd_n, res1;
    reg  [7:0] di1;
    wire [7:0] rdata1; wire ack1;

    external_bus #(.CLK_HZ(CLK_HZ), .PHI0_HZ(1_000_000), .STYLE(1)) u1 (
        .clk(clk), .rst_n(rst_n),
        .addr(addr), .wdata(wdata), .rdata(rdata1),
        .req(req & style), .we(we), .ack(ack1),
        .card_reset(1'b0), .irq(),
        .ext_a(a1), .ext_d_in(di1), .ext_d_out(do1), .ext_d_oe(oe1),
        .ext_sel_n(s1), .ext_rw(wr_n), .ext_phi0(rd_n),
        .ext_res_n(res1), .ext_irq_n(1'b1)
    );

    wire [7:0] rdata = style ? rdata1 : rdata0;
    wire       ack   = style ? ack1   : ack0;

    // Card read data: whatever register the active select points at.
    always @* begin
        di0 = (s0[0] == 1'b0) ? card[a0] : 8'hFF;
        di1 = (s1[0] == 1'b0) ? card[a1] : 8'hFF;
    end

    // Card writes. Style 0 latches on the falling edge of PHI0 with R/W low
    // (a 6502 card samples data at the end of the high phase); style 1 on the
    // rising edge of WR#.
    always @(negedge phi0_0) if (!s0[0] && !rw0) card[a0] <= do0;
    always @(posedge wr_n)   if (!s1[0])         card[a1] <= do1;

    //------------------------------------------------------------------
    task bus_write(input [10:0] ad, input [7:0] d);
        begin
            @(posedge clk); addr <= ad; wdata <= d; we <= 1; req <= 1;
            @(posedge clk); while (!ack) @(posedge clk);
            req <= 0; we <= 0; @(posedge clk);
        end
    endtask

    task bus_read(input [10:0] ad, output [7:0] d);
        begin
            @(posedge clk); addr <= ad; we <= 0; req <= 1;
            @(posedge clk); while (!ack) @(posedge clk);
            d = rdata;
            req <= 0; @(posedge clk);
        end
    endtask

    reg [7:0] d;
    integer t0, t1;

    initial begin
        $dumpfile("tb_extbus.vcd"); $dumpvars(0, tb_extbus);
        req = 0; we = 0; addr = 0; wdata = 0;
        for (i = 0; i < 16; i = i + 1) card[i] = 8'h00;
        repeat (5) @(posedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        //--------------------------------------------------------------
        $display("-- style 0 (6502: PHI0 + R/W) --");
        style = 0;
        check("res_n released", res0, 1'b1);

        bus_write(11'h003, 8'h5A);
        check("card[3] written", card[3], 8'h5A);

        card[7] = 8'hA5;
        bus_read(11'h007, d);
        check("card[7] read", d, 8'hA5);

        // A read of an unselected card must not disturb card 0.
        bus_read(11'h017, d);
        check("card 1 reads FF", d, 8'hFF);
        check("sel_n idle", s0, 4'b1111);

        // Selects are one-hot-low and follow addr[5:4].
        check("sel decode c2", (11'h027 & 11'h030) >> 4, 32'd2);

        // Back-to-back accesses must not merge: the second must produce its
        // own strobe, which is what S_GAP exists to guarantee.
        card[1] = 8'h11; card[2] = 8'h22;
        bus_read(11'h001, d); check("b2b first",  d, 8'h11);
        bus_read(11'h002, d); check("b2b second", d, 8'h22);

        // A cycle must take roughly one to two PHI0 periods (1-2 us).
        t0 = $time; bus_read(11'h001, d); t1 = $time;
        $display("  6502 cycle = %0d ns", t1 - t0);
        if ((t1 - t0) < 900 || (t1 - t0) > 2600) begin
            $display("FAIL cycle length out of range"); errors = errors + 1;
        end

        //--------------------------------------------------------------
        $display("-- style 1 (Intel: RD# / WR#) --");
        style = 1;
        check("res_n released", res1, 1'b1);
        check("strobes idle high", {wr_n, rd_n}, 2'b11);

        bus_write(11'h004, 8'h3C);
        check("card[4] written", card[4], 8'h3C);

        card[9] = 8'hC3;
        bus_read(11'h009, d);
        check("card[9] read", d, 8'hC3);

        bus_read(11'h039, d);
        check("card 3 reads FF", d, 8'hFF);

        t0 = $time; bus_read(11'h009, d); t1 = $time;
        $display("  intel cycle = %0d ns", t1 - t0);

        //--------------------------------------------------------------
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end

    initial begin #200000; $display("FAIL timeout"); $finish; end
endmodule
`default_nettype wire
