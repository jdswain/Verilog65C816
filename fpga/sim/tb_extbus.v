// tb_extbus.v -- external_bus.v against a model of the carrier: a 74HCT138
// on the select code and enable, and a 16-register card on each of its
// eight outputs. Checks the decode and its mirroring, the cycle's timing
// against docs/Hardware.md, that the decoder never sees the code change
// while it is enabled, the SCC's recovery time on slot 2, and the reset
// (both strobes low while RES# is asserted).
//
//   iverilog -g2005 -o tb_extbus rtl/external_bus.v sim/tb_extbus.v && vvp tb_extbus
`timescale 1ns/1ps
`default_nettype none

module tb_extbus;
    reg clk = 0, rst_n = 0;
    always #(500.0/25.2) clk = ~clk;          // 25.2 MHz

    integer errors = 0;
    task check(input [255:0] name, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %h expected %h", name, got, exp);
            errors = errors + 1;
        end else $display("  ok  %0s = %h", name, got);
    endtask
    task check_ge(input [255:0] name, input real got, input real min);
        if (got < min) begin
            $display("FAIL %0s: %0.1f ns, want at least %0.1f", name, got, min);
            errors = errors + 1;
        end else $display("  ok  %0s = %0.1f ns (>= %0.1f)", name, got, min);
    endtask

    //------------------------------------------------------------------
    reg [10:0] addr; reg [7:0] wdata; reg req, we, card_reset;
    wire [7:0] rdata; wire ack;
    wire [3:0] ext_a; wire [7:0] d_out; wire d_oe;
    wire [2:0] sel; wire sel_en_n, rd_n, wr_n, res_n, irq;
    reg  [7:0] d_in;

    external_bus dut (
        .clk(clk), .rst_n(rst_n),
        .addr(addr), .wdata(wdata), .rdata(rdata),
        .req(req), .we(we), .ack(ack),
        .card_reset(card_reset), .irq(irq),
        .ext_a(ext_a), .ext_d_in(d_in), .ext_d_out(d_out), .ext_d_oe(d_oe),
        .ext_sel(sel), .ext_sel_en_n(sel_en_n),
        .ext_rd_n(rd_n), .ext_wr_n(wr_n),
        .ext_res_n(res_n), .ext_irq_n(1'b1)
    );

    // The '138: output n low while enabled with code n.
    wire [7:0] cs_n = sel_en_n ? 8'hFF : ~(8'd1 << sel);

    // Eight cards of 16 registers. A write lands on WR#'s rising edge; a
    // read drives the bus while its select and RD# are low.
    reg [7:0] card [0:127];
    integer i, k;
    always @* begin
        d_in = 8'hFF;
        for (k = 0; k < 8; k = k + 1)
            if (!cs_n[k] && !rd_n) d_in = card[k*16 + ext_a];
    end
    always @(posedge wr_n)
        for (k = 0; k < 8; k = k + 1)
            if (!cs_n[k]) card[k*16 + ext_a] <= d_out;

    //------------------------------------------------------------------
    // Timing monitors: when each edge happened, and the rules that must
    // hold at every edge.
    realtime t_addr, t_en_fall, t_strobe_fall, t_strobe_rise, t_en_rise;
    realtime t_scc_fall, scc_gap_min, other_gap_min, t_prev_fall;
    reg      prev_was_scc;
    initial begin
        t_addr = 0; t_scc_fall = -1e9; t_prev_fall = -1e9;
        scc_gap_min = 1e9; other_gap_min = 1e9; prev_was_scc = 0;
    end
    always @(ext_a or sel) begin
        t_addr = $realtime;
        if (!sel_en_n) begin
            $display("FAIL address or code changed while enabled at %0t", $time);
            errors = errors + 1;
        end
    end
    always @(negedge sel_en_n) t_en_fall = $realtime;
    always @(posedge sel_en_n) t_en_rise = $realtime;
    always @(negedge rd_n or negedge wr_n) if (res_n) begin
        t_strobe_fall = $realtime;
        if (sel_en_n) begin
            $display("FAIL strobe without the enable at %0t", $time);
            errors = errors + 1;
        end
        if (sel == 3'd2) begin
            if ($realtime - t_scc_fall < scc_gap_min) scc_gap_min = $realtime - t_scc_fall;
            t_scc_fall = $realtime;
        end else if (!prev_was_scc) begin
            if ($realtime - t_prev_fall < other_gap_min) other_gap_min = $realtime - t_prev_fall;
        end
        prev_was_scc = (sel == 3'd2);
        t_prev_fall = $realtime;
    end
    always @(posedge rd_n or posedge wr_n) if (!sel_en_n) t_strobe_rise = $realtime;
    // Write data must be on the bus for the whole of WR# and its hold.
    always @(posedge wr_n) if (!sel_en_n && !d_oe) begin
        $display("FAIL write data not driven at WR# rising, %0t", $time);
        errors = errors + 1;
    end
    always @(negedge d_oe) if (!sel_en_n) begin
        $display("FAIL data released before the enable, %0t", $time);
        errors = errors + 1;
    end

    //------------------------------------------------------------------
    task bus_write(input [10:0] ad, input [7:0] d);
        begin
            @(posedge clk); addr <= ad; wdata <= d; we <= 1; req <= 1;
            @(posedge clk); while (!ack) @(posedge clk);
            req <= 0; we <= 0;
        end
    endtask

    task bus_read(input [10:0] ad, output [7:0] d);
        begin
            @(posedge clk); addr <= ad; we <= 0; req <= 1;
            @(posedge clk); while (!ack) @(posedge clk);
            d = rdata;
            req <= 0;
        end
    endtask

    reg [7:0] d;
    realtime t0, t1;
    integer strobes;
    always @(negedge rd_n or negedge wr_n) if (res_n) strobes = strobes + 1;

    initial begin
        $dumpfile("tb_extbus.vcd"); $dumpvars(0, tb_extbus);
        req = 0; we = 0; addr = 0; wdata = 0; card_reset = 0; strobes = 0;
        for (i = 0; i < 128; i = i + 1) card[i] = 8'h00;

        // In reset: RES# and both strobes low, the decoder off.
        repeat (3) @(posedge clk);
        check("reset: RES#", res_n, 1'b0);
        check("reset: RD# WR# low", {rd_n, wr_n}, 2'b00);
        check("reset: enable off", sel_en_n, 1'b1);
        rst_n = 1;
        repeat (3) @(posedge clk);
        check("RES# released", res_n, 1'b1);
        check("strobes idle high", {rd_n, wr_n}, 2'b11);

        //--------------------------------------------------------------
        $display("-- decode --");
        for (i = 0; i < 8; i = i + 1)
            bus_write(11'h000 + i*16 + 5, 8'h50 + i);
        for (i = 0; i < 8; i = i + 1)
            check("slot written", card[i*16 + 5], 8'h50 + i);
        card[3*16 + 9] = 8'hA5;
        bus_read(11'h039, d);   check("slot 3 reg 9", d, 8'hA5);
        bus_read(11'h0B9, d);   check("mirror +128", d, 8'hA5);
        bus_read(11'h7B9, d);   check("mirror at the top", d, 8'hA5);
        bus_read(11'h049, d);   check("slot 4 reg 9", d, 8'h00);

        //--------------------------------------------------------------
        $display("-- timing --");
        t0 = $realtime; bus_read(11'h001, d); t1 = $realtime;
        $display("  read, request to ack = %0.1f ns", t1 - t0);
        check_ge("address to enable", t_en_fall - t_addr, 39.0);
        check_ge("address to strobe", t_strobe_fall - t_addr, 118.0);
        check_ge("strobe width", t_strobe_rise - t_strobe_fall, 237.0);
        check_ge("strobe to enable release", t_en_rise - t_strobe_rise, 39.0);
        if (t1 - t0 > 600.0) begin
            $display("FAIL cycle too long"); errors = errors + 1;
        end
        bus_write(11'h002, 8'h77);
        check_ge("write strobe width", t_strobe_rise - t_strobe_fall, 237.0);
        check_ge("write: strobe to enable release", t_en_rise - t_strobe_rise, 39.0);

        //--------------------------------------------------------------
        $display("-- SCC recovery --");
        // Back to back on slot 0: no wait. On slot 2: 595 ns between strobes.
        other_gap_min = 1e9;
        for (i = 0; i < 4; i = i + 1) bus_read(11'h004, d);
        $display("  slot 0, strobe to strobe = %0.1f ns", other_gap_min);
        if (other_gap_min >= 595.0) begin
            $display("FAIL slot 0 was held off as the SCC is"); errors = errors + 1;
        end
        scc_gap_min = 1e9;
        for (i = 0; i < 4; i = i + 1) bus_read(11'h022, d);
        bus_write(11'h023, 8'h12);
        bus_read(11'h0A2, d);                       // a mirror is still slot 2
        check_ge("slot 2, strobe to strobe", scc_gap_min, 595.0);
        // Another slot in between doesn't reset the SCC's clock.
        scc_gap_min = 1e9;
        bus_read(11'h022, d); bus_read(11'h001, d); bus_read(11'h022, d);
        check_ge("slot 2 around slot 0", scc_gap_min, 595.0);

        //--------------------------------------------------------------
        $display("-- card reset --");
        card_reset = 1;
        repeat (2) @(posedge clk);
        check("RES#", res_n, 1'b0);
        check("RD# WR# low together", {rd_n, wr_n}, 2'b00);
        check("enable off", sel_en_n, 1'b1);
        strobes = 0;
        card[3*16 + 1] = 8'h3C;
        bus_read(11'h031, d);   check("read in reset", d, 8'hFF);
        bus_write(11'h031, 8'h99);
        check("write in reset ignored", card[3*16 + 1], 8'h3C);
        check("enable stayed off", sel_en_n, 1'b1);
        card_reset = 0;
        repeat (2) @(posedge clk);
        check("strobes high after reset", {rd_n, wr_n}, 2'b11);
        bus_read(11'h031, d);   check("read after reset", d, 8'h3C);

        //--------------------------------------------------------------
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end

    initial begin #200000; $display("FAIL timeout"); $finish; end
endmodule
`default_nettype wire
