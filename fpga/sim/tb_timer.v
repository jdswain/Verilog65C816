// tb_timer.v -- the tick timer (timer.v)
//
// The checks: the period is exactly RELOAD clocks from the enabling write
// and between ticks, RELOAD = 0 gives 65536, PENDING is set at each tick and
// cleared by writing 1 (writing 0 leaves it), TICKS counts while PENDING is
// left set, a read of +8 latches TICKS and NOW together, a RELOAD write
// takes effect at the next tick, EN = 0 stops both counters, and a write of
// EN = 1 while running does not restart the period.
//
//   iverilog -g2005 -o tb_timer rtl/timer.v sim/tb_timer.v && vvp tb_timer
`timescale 1ns/1ps
`default_nettype none

module tb_timer;
    reg clk = 0, rst_n = 0;
    always #(500.0/25.2) clk = ~clk;

    integer errors = 0;
    task check(input [255:0] name, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %h expected %h", name, got, exp);
            errors = errors + 1;
        end else $display("  ok  %0s = %h", name, got);
    endtask

    reg  [3:0] a; reg [7:0] wd; reg cs = 0, we = 0;
    wire [7:0] rd; wire pending;

    timer u (.clk(clk), .rst_n(rst_n), .reg_addr(a), .wdata(wd), .rdata(rd),
             .cs(cs), .we(we), .pending(pending));

    // Registers are read as the SoC does: rdata captured on the strobe.
    task wr(input [3:0] ad, input [7:0] v);
        begin
            @(negedge clk); a = ad; wd = v; cs = 1; we = 1;
            @(negedge clk); cs = 0; we = 0;
        end
    endtask
    reg [7:0] q;
    task rdr(input [3:0] ad);
        begin
            @(negedge clk); a = ad; cs = 1; we = 0;
            @(posedge clk); q = rd;
            @(negedge clk); cs = 0;
        end
    endtask

    // The clock count, the edge of each tick (PENDING set, TICKS counted)
    // and of each write that enables the timer, for measuring periods.
    integer cyc = 0, t_tick = 0, t_prev = 0, t_en = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (u.tick) begin t_prev = t_tick; t_tick = cyc; end
        if (cs & we & (a == 4'd2) & wd[0] & ~u.en) t_en = cyc;
    end
    integer n;
    task wait_tick;                     // until the next tick has happened
        begin
            n = t_tick;
            while (t_tick == n) @(posedge clk);
            @(negedge clk);
        end
    endtask

    reg [31:0] t32; reg [15:0] now16;
    task snapshot;
        begin
            rdr(8);  t32[7:0]   = q;
            rdr(9);  t32[15:8]  = q;
            rdr(10); t32[23:16] = q;
            rdr(11); t32[31:24] = q;
            rdr(4);  now16[7:0] = q;
            rdr(5);  now16[15:8] = q;
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_timer.vcd"); $dumpvars(0, tb_timer);
        end
        repeat (3) @(posedge clk); rst_n = 1;

        rdr(2); check("CTRL at reset", q, 8'h00);
        rdr(3); check("STATUS at reset", q, 8'h00);

        // ---- the period: 100 clocks ----
        wr(0, 8'd100); wr(1, 8'd0);
        rdr(0); check("RELOAD low", q, 8'd100);
        wr(2, 8'h01);
        wait_tick;
        check("first period", t_tick - t_en, 32'd100);
        check("PENDING at the tick", pending, 1'b1);
        wr(3, 8'h00);
        check("write 0 leaves PENDING", pending, 1'b1);
        wr(3, 8'h01);
        check("write 1 clears PENDING", pending, 1'b0);
        wait_tick;
        check("second period", t_tick - t_prev, 32'd100);

        // ---- TICKS keep counting with PENDING left set ----
        repeat (250) @(posedge clk);
        snapshot;
        check("TICKS after 2 + 250 clocks", t32 >= 4 && t32 <= 5, 1);
        // NOW and TICKS are a pair: the time since reset in clocks is
        // TICKS*100 + (99 - NOW); a second snapshot must agree with the
        // clocks between the two +8 reads (each snapshot is 6 reads, 12
        // clocks)
        begin : pair
            reg [31:0] t1; reg [31:0] e1, e2;
            e1 = t32 * 100 + (99 - now16); t1 = t32;
            snapshot;
            e2 = t32 * 100 + (99 - now16);
            check("snapshots agree", e2 - e1, 32'd12);
        end
        check("PENDING still set", pending, 1'b1);

        // ---- a write of EN = 1 while running does not restart ----
        wr(3, 8'h01);
        rdr(8); rdr(4); now16[7:0] = q; rdr(5); now16[15:8] = q;
        begin : norestart
            reg [15:0] before;
            before = now16;
            wr(2, 8'h01);
            rdr(8); rdr(4); now16[7:0] = q; rdr(5); now16[15:8] = q;
            // 8 clocks later (the write, the +8 and two reads), modulo 100
            check("EN rewrite keeps the period",
                  (before + 100 - now16) % 100, 32'd8);
        end

        // ---- RELOAD takes effect at the next tick ----
        wr(0, 8'd40);
        wr(3, 8'h01);
        wait_tick;                              // the old period ends
        wait_tick;
        check("new RELOAD at the next tick", t_tick - t_prev, 32'd40);

        // ---- EN = 0 stops it ----
        wr(2, 8'h00);
        wr(3, 8'h01);
        snapshot;
        repeat (500) @(posedge clk);
        check("stopped: no PENDING", pending, 1'b0);
        begin : stopped
            reg [31:0] t0; reg [15:0] n0;
            t0 = t32; n0 = now16;
            snapshot;
            check("stopped: TICKS", t32, t0);
            check("stopped: NOW", now16, n0);
        end
        rdr(2); check("CTRL EN = 0", q, 8'h00);

        // ---- RELOAD = 0 is 65536 clocks ----
        wr(0, 8'd0); wr(1, 8'd0);
        wr(2, 8'h01);
        wait_tick;
        check("RELOAD 0: the first period", t_tick - t_en, 32'd65536);
        wait_tick;
        check("RELOAD 0: the next", t_tick - t_prev, 32'd65536);

        // ---- RELOAD = 1: every clock ----
        wr(2, 8'h00); wr(0, 8'd1); wr(1, 8'd0);
        snapshot;
        begin : every
            reg [31:0] t0;
            t0 = t32;
            wr(2, 8'h01);
            repeat (20) @(posedge clk);
            wr(2, 8'h00);
            snapshot;
            check("RELOAD 1: one tick a clock", t32 - t0, 32'd21);
        end

        if (errors == 0) $display("tb_timer: PASS");
        else             $display("tb_timer: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
