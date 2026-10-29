//============================================================================
// tb_sd_spi.v -- the SD controller against the card model (sd_card_model.v)
//
// An access is made as soc.v makes it: a one-cycle strobe, then the second
// cycle held while `stall` is high; DATA and NEXT are read from `rx` when it
// ends, STATUS and DIVIDER from `rdata` on the strobe. It runs the card's
// start-up at the slow clock, then at the fast one reads, writes, and reads
// back single and multiple blocks, with NEXT, checking the data and CRCs
// against the card's memory. NEXT reads go back to back (so they wait) and
// at random spacings (so some land as an exchange ends). It checks the SCLK
// rates, the exchange time, and that SCLK and MOSI idle low and high.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_sd_spi;
    reg clk = 0; always #19.84 clk = ~clk;
    reg rst_n = 0;

    reg  [1:0] reg_addr = 0;
    reg  [7:0] wdata = 0;
    reg        cs = 0, we = 0;
    wire [7:0] rdata, rx;
    wire       stall, sd_clk, sd_mosi, sd_cs_n, card_miso, card_oe;
    wire       sd_miso = card_oe ? card_miso : 1'b1;   // the pin's pull-up

    sd_spi #(.SYS_HZ(25_200_000)) dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .wdata(wdata), .rdata(rdata), .rx(rx),
        .cs(cs), .we(we), .stall(stall),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso)
    );

    sd_card_model #(.BLOCKS(2048)) card (
        .sclk(sd_clk), .mosi(sd_mosi), .cs_n(sd_cs_n),
        .miso(card_miso), .miso_oe(card_oe)
    );

    integer errors = 0, stalls = 0, cyc = 0;
    always @(posedge clk) cyc = cyc + 1;
    always @(posedge clk) if (stall) stalls = stalls + 1;

    task fail(input [80*8-1:0] what, input [31:0] got, input [31:0] want);
        begin
            $display("FAIL %0s: got %h, want %h", what, got, want);
            errors = errors + 1;
        end
    endtask

    // One access, as soc.v makes it.
    reg [7:0] q;
    task acc(input [1:0] a, input w, input [7:0] d);
        begin
            @(negedge clk); reg_addr = a; we = w; wdata = d; cs = 1;
            #1 q = rdata;                // STATUS and DIVIDER: on the strobe
            @(negedge clk); cs = 0; we = 0;
            while (stall) @(negedge clk);
            if (a < 2) q = rx;           // DATA and NEXT: when it ends
        end
    endtask

    task xfer(input [7:0] d, output [7:0] r);
        begin acc(0, 1, d); acc(0, 0, 0); r = q; end
    endtask

    // A command; r1 is the first byte that is not $FF.
    reg [7:0] r1, b, t;
    integer n;
    task command(input [5:0] c, input [31:0] arg, input [7:0] crc);
        begin
            xfer(8'hFF, b);
            xfer({2'b01, c}, b);
            xfer(arg[31:24], b); xfer(arg[23:16], b);
            xfer(arg[15:8], b);  xfer(arg[7:0], b);
            xfer(crc, b);
            r1 = 8'hFF;
            for (n = 0; n < 10 && r1 == 8'hFF; n = n + 1) xfer(8'hFF, r1);
        end
    endtask

    // Wait for the data token with NEXT.
    task token;
        begin
            acc(1, 0, 0);
            for (n = 0; n < 100 && q != 8'hFE; n = n + 1) acc(1, 0, 0);
            if (q != 8'hFE) fail("data token", q, 8'hFE);
        end
    endtask

    function [15:0] crc16(input integer base);
        integer k, j;
        reg [15:0] c;
        begin
            c = 0;
            for (k = 0; k < 512; k = k + 1) begin
                c = c ^ {card.mem[base + k], 8'h00};
                for (j = 0; j < 8; j = j + 1)
                    c = c[15] ? {c[14:0], 1'b0} ^ 16'h1021 : {c[14:0], 1'b0};
            end
            crc16 = c;
        end
    endfunction

    // Read a block with NEXT, after its token, and check it and its CRC.
    // gap > 0: up to that many clocks between reads, at random.
    integer seed = 5, gap = 0;
    task check_block(input integer blk);
        integer k, bad;
        reg [15:0] c;
        begin
            token;
            bad = 0;
            for (k = 0; k < 512; k = k + 1) begin
                if (gap > 0) repeat ({$random(seed)} % gap) @(negedge clk);
                acc(1, 0, 0);
                if (q !== card.mem[blk*512 + k]) begin
                    if (bad < 3) $display("FAIL block %0d byte %0d: %h, want %h",
                                          blk, k, q, card.mem[blk*512 + k]);
                    bad = bad + 1;
                end
            end
            acc(1, 0, 0); c[15:8] = q;
            acc(1, 0, 0); c[7:0] = q;
            if (c !== crc16(blk*512)) fail("block CRC", c, crc16(blk*512));
            if (bad) errors = errors + 1;
        end
    endtask

    // Write a block after its token; check the data response and wait out
    // the busy bytes.
    task write_block(input [7:0] tok, input integer seedv);
        integer k;
        begin
            xfer(8'hFF, b);
            xfer(tok, b);
            for (k = 0; k < 512; k = k + 1) xfer((k * seedv + seedv) & 8'hFF, b);
            xfer(8'h00, b); xfer(8'h00, b);          // CRC, not checked
            xfer(8'hFF, b);
            if ((b & 8'h1F) != 8'h05) fail("data response", b, 8'h05);
            for (k = 0; k < 20 && b != 8'hFF; k = k + 1) xfer(8'hFF, b);
            if (b != 8'hFF) fail("still busy", b, 8'hFF);
        end
    endtask

    task check_written(input integer blk, input integer seedv);
        integer k, bad;
        begin
            bad = 0;
            for (k = 0; k < 512; k = k + 1)
                if (card.mem[blk*512 + k] !== ((k * seedv + seedv) & 8'hFF)) bad = bad + 1;
            if (bad) fail("written block", blk, bad);
        end
    endtask

    // SCLK's period, from two rising edges, in clocks.
    integer t0, t1, period;
    task measure;
        begin
            fork
                begin acc(0, 1, 8'hFF); end
                begin @(posedge sd_clk); t0 = cyc; @(posedge sd_clk); t1 = cyc; end
            join
            period = t1 - t0;
            // an exchange on its own: from the write's strobe to BUSY clearing
            acc(2, 0, 0); while (q[7]) acc(2, 0, 0);
            acc(0, 1, 8'hFF);
            acc(2, 0, 0); while (q[7]) acc(2, 0, 0);
        end
    endtask
    integer x_start, x_end;
    always @(posedge clk) begin
        if (cs & we & (reg_addr == 0) & ~dut.busy) x_start = cyc;
        if (dut.busy) x_end = cyc + 1;
    end

    integer k;
    initial begin
        for (k = 0; k < 2048*512; k = k + 1) card.mem[k] = (k * 37 + (k >> 9) * 11 + 5) & 8'hFF;
        card.present = 1'b1;
        repeat (3) @(posedge clk); rst_n = 1;

        // ---- reset state ----
        acc(3, 0, 0); if (q != 8'd31) fail("DIVIDER at reset", q, 31);
        acc(2, 0, 0); if (q != 8'h00) fail("STATUS at reset", q, 0);
        if (sd_cs_n !== 1'b1 || sd_clk !== 1'b0 || sd_mosi !== 1'b1)
            fail("idle pins (cs_n, clk, mosi)", {sd_cs_n, sd_clk, sd_mosi}, 3'b101);

        // ---- the slow clock ----
        measure;
        if (period != 64) fail("SCLK period at 31", period, 64);
        if (x_end - x_start != 16*32 + 1) fail("exchange at 31", x_end - x_start, 16*32 + 1);
        $display("DIVIDER 31: SCLK %0d clocks, exchange %0d clocks", period, x_end - x_start);

        // 80 clocks with the card deselected, then select it.
        for (k = 0; k < 10; k = k + 1) xfer(8'hFF, b);
        acc(2, 1, 8'h01);
        acc(2, 0, 0); if (q != 8'h01) fail("STATUS selected", q, 1);
        if (sd_cs_n !== 1'b0) fail("cs_n selected", sd_cs_n, 0);

        command(0, 0, 8'h00);            // CMD0, CRC wrong
        if (r1 != 8'h09) fail("CMD0, bad CRC", r1, 8'h09);
        command(0, 0, 8'h95);
        if (r1 != 8'h01) fail("CMD0", r1, 8'h01);
        command(8, 32'h1AA, 8'h87);
        if (r1 != 8'h01) fail("CMD8", r1, 8'h01);
        xfer(8'hFF, b); xfer(8'hFF, b); xfer(8'hFF, b); t = b; xfer(8'hFF, b);
        if ({t, b} != 16'h01AA) fail("CMD8 echo", {t, b}, 16'h01AA);
        for (k = 0; k < 5 && r1 != 8'h00; k = k + 1) begin
            command(55, 0, 8'h01);
            command(41, 32'h40000000, 8'h01);
        end
        if (r1 != 8'h00) fail("ACMD41 ready", r1, 0);
        if (k != 2) fail("ACMD41 tries", k, 2);
        command(58, 0, 8'h01);
        xfer(8'hFF, b); if (b != 8'hC0) fail("OCR: powered up, CCS", b, 8'hC0);
        xfer(8'hFF, b); xfer(8'hFF, b); xfer(8'hFF, b);

        // ---- the fast clock ----
        acc(3, 1, 8'd0);
        measure;
        if (period != 2) fail("SCLK period at 0", period, 2);
        if (x_end - x_start != 17) fail("exchange at 0", x_end - x_start, 17);
        $display("DIVIDER 0: SCLK %0d clocks, exchange %0d clocks", period, x_end - x_start);

        command(16, 512, 8'h01);
        if (r1 != 8'h00) fail("CMD16", r1, 0);

        command(9, 0, 8'h01);            // the CSD: C_SIZE = 2048 / 1024 - 1
        token;
        for (k = 0; k < 18; k = k + 1) begin
            acc(1, 0, 0);
            if (k == 9 && q != 8'd1) fail("CSD C_SIZE", q, 1);
        end

        // A block, read back to back: every NEXT waits.
        stalls = 0;
        command(17, 3, 8'h01);
        if (r1 != 8'h00) fail("CMD17", r1, 0);
        check_block(3);
        if (stalls < 512) fail("NEXT waited", stalls, 512);
        $display("CMD17 back to back: %0d clocks stalled", stalls);

        // Write a block and read it back.
        command(24, 5, 8'h01);
        if (r1 != 8'h00) fail("CMD24", r1, 0);
        write_block(8'hFE, 7);
        check_written(5, 7);
        command(17, 5, 8'h01);
        check_block(5);

        // Three blocks with CMD18, NEXT at random spacings, then CMD12.
        gap = 40;
        command(18, 6, 8'h01);
        if (r1 != 8'h00) fail("CMD18", r1, 0);
        check_block(6); check_block(7); check_block(8);
        gap = 0;
        command(12, 0, 8'h01);
        if (r1 != 8'h00) fail("CMD12", r1, 0);
        for (k = 0; k < 20 && b != 8'hFF; k = k + 1) xfer(8'hFF, b);

        // Two blocks with CMD25.
        command(25, 10, 8'h01);
        if (r1 != 8'h00) fail("CMD25", r1, 0);
        write_block(8'hFC, 3);
        write_block(8'hFC, 9);
        xfer(8'hFD, b);                  // stop tran
        xfer(8'hFF, b);                  // a byte, then busy
        xfer(8'hFF, b); if (b != 8'h00) fail("busy after stop tran", b, 0);
        for (k = 0; k < 20 && b != 8'hFF; k = k + 1) xfer(8'hFF, b);
        if (b != 8'hFF) fail("busy after stop tran", b, 8'hFF);
        check_written(10, 3);
        check_written(11, 9);

        // Deselect: chip select, SCLK and MOSI back to idle.
        acc(2, 1, 8'h00);
        xfer(8'hFF, b);
        if (sd_cs_n !== 1'b1 || sd_clk !== 1'b0 || sd_mosi !== 1'b1)
            fail("idle pins after", {sd_cs_n, sd_clk, sd_mosi}, 3'b101);

        // No card: MISO floats high.
        card.present = 1'b0;
        acc(2, 1, 8'h01);
        xfer(8'h40, b); if (b != 8'hFF) fail("no card", b, 8'hFF);

        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end

    initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
