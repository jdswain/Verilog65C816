//============================================================================
// tb_blitter.v -- random blits checked against a model that knows nothing
// about words, shifts or masks.
//
// The reference is an array of pixels. A blit is modelled as the definition
// says: for each line, take the source pixels as they stand, then combine
// each with its destination pixel. Whatever the hardware does with 32-bit
// words, bursts and end masks has to come out the same, for every alignment
// of source and destination, every logic operation, overlapping or not, top
// down or bottom up.
//
// A second master reads continuously on the CPU's port throughout, to check
// that the blitter leaves it room and that sharing the controller does not
// disturb either of them.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_blitter;
    localparam integer WORDS  = 16384;           // 64 KB
    localparam integer PIXELS = WORDS * 8;

    reg clk = 0; always #19.84 clk = ~clk;
    reg rst_n = 0;

    reg  [4:0] reg_addr = 0;
    reg  [7:0] wdata = 0;
    wire [7:0] rdata;
    reg        cs = 0, we = 0;

    wire        m_req, m_we, m_done, m_rvalid, busy;
    wire [20:0] m_addr;
    wire [31:0] m_wdata, m_rdata;
    wire [3:0]  m_wmask;

    blitter dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .wdata(wdata), .rdata(rdata), .cs(cs), .we(we),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_wmask(m_wmask), .m_done(m_done), .m_rvalid(m_rvalid), .m_rdata(m_rdata),
        .busy(busy)
    );

    // The competing reader on port 1.
    reg         c_req = 0;
    reg  [20:0] c_addr = 0;
    wire        c_done, c_rvalid;
    integer     c_count = 0, c_errors = 0;

    wire [10:0] sa; wire [1:0] sba; wire [3:0] sdqm; wire [31:0] sdq;
    wire scs, sras, scas, swe, scke, idone;

    sdram_burst #(.FREQ(25_200_000)) u_sd (
        .clk(clk), .rst_n(rst_n),
        .p0_req(1'b0), .p0_we(1'b0), .p0_addr(21'd0), .p0_wdata(32'd0),
        .p0_wmask(4'd0), .p0_done(), .p0_rvalid(),
        .p1_req(c_req), .p1_we(1'b0), .p1_addr(c_addr), .p1_wdata(32'd0),
        .p1_wmask(4'd0), .p1_done(c_done), .p1_rvalid(c_rvalid),
        .p2_req(m_req), .p2_we(m_we), .p2_addr(m_addr), .p2_wdata(m_wdata),
        .p2_wmask(m_wmask), .p2_done(m_done), .p2_rvalid(m_rvalid),
        .rdata(m_rdata), .init_done(idone),
        .sdram_a(sa), .sdram_ba(sba), .sdram_dq(sdq), .sdram_dqm(sdqm),
        .sdram_cs_n(scs), .sdram_ras_n(sras), .sdram_cas_n(scas),
        .sdram_we_n(swe), .sdram_cke(scke)
    );

    sdram_model #(.MEM_WORDS(WORDS), .CAS(2)) mem (
        .clk(~clk), .cke(scke), .cs_n(scs), .ras_n(sras), .cas_n(scas),
        .we_n(swe), .a(sa), .ba(sba), .dqm(sdqm), .dq(sdq)
    );

    // The reader works a region the blits never touch, so it knows what it
    // should get back: word n holds ~n.
    localparam integer QUIET = WORDS - 256;
    reg run_reader = 0;
    integer cb;
    initial forever begin
        @(posedge clk);
        if (run_reader) begin
            c_addr = QUIET + (($random & 63) << 2);
            c_req  = 1;
            cb     = 0;
            while (!c_done) begin
                @(posedge clk); #1;
                if (c_rvalid) begin
                    if (m_rdata !== ~(c_addr + cb)) c_errors = c_errors + 1;
                    cb = cb + 1;
                end
            end
            c_req = 0;
            c_count = c_count + 1;
            @(posedge clk);
        end
    end

    //------------------------------------------------------------------
    task wr(input [4:0] a, input [7:0] d);
        begin
            @(negedge clk); reg_addr = a; wdata = d; we = 1; cs = 1;
            @(negedge clk); cs = 0; we = 0;
        end
    endtask
    task wr16(input [4:0] a, input [15:0] d);
        begin wr(a, d[7:0]); wr(a + 5'd1, d[15:8]); end
    endtask
    task wr24(input [4:0] a, input [23:0] d);
        begin wr(a, d[7:0]); wr(a + 5'd1, d[15:8]); wr(a + 5'd2, d[23:16]); end
    endtask

    //------------------------------------------------------------------
    // Reference model
    //------------------------------------------------------------------
    reg [3:0] refp [0:PIXELS-1];
    reg [3:0] line [0:1023];

    function [3:0] rop4(input [3:0] op, input [3:0] s, input [3:0] d);
        integer b;
        begin
            for (b = 0; b < 4; b = b + 1)
                rop4[b] = op[{~s[b], ~d[b]}];
        end
    endfunction

    integer errors = 0, tests = 0;
    integer src, dst, sst, dst_st, w, h, op, fill, key, fmode, tmode;
    integer x, y, n, i, a, lo, hi, tries, ok, t_start, t_cyc, cyc = 0;
    always @(posedge clk) cyc = cyc + 1;
    reg [3:0] s4, d4;
    reg [31:0] word;

    task model;
        begin
            for (y = 0; y < h; y = y + 1) begin
                for (x = 0; x < w; x = x + 1)
                    line[x] = fmode ? fill[3:0] : refp[src + y*sst + x];
                for (x = 0; x < w; x = x + 1) begin
                    s4 = line[x];
                    d4 = refp[dst + y*dst_st + x];
                    if (!(tmode && s4 == key[3:0]))
                        refp[dst + y*dst_st + x] = rop4(op[3:0], s4, d4);
                end
            end
        end
    endtask

    task run_blit;
        begin
            wr24(5'h00, src[23:0]);
            wr24(5'h04, dst[23:0]);
            wr16(5'h08, sst[15:0]);
            wr16(5'h0A, dst_st[15:0]);
            wr16(5'h0C, w[15:0]);
            wr16(5'h0E, h[15:0]);
            wr(5'h10, op[7:0]);
            wr(5'h11, {key[3:0], fill[3:0]});
            t_start = cyc;
            wr(5'h12, {5'd0, tmode[0], fmode[0], 1'b1});
            @(posedge clk); #1;
            if (!busy) begin
                $display("FAIL: not busy after start"); errors = errors + 1;
            end
            while (busy) @(posedge clk);
            t_cyc = cyc - t_start;
        end
    endtask

    task check(input [200*8-1:0] what);
        integer bad;
        begin
            bad = 0;
            for (n = 0; n < PIXELS - 2048; n = n + 1) begin
                word = mem.mem[n >> 3];
                if (word[(n & 7)*4 +: 4] !== refp[n]) begin
                    if (bad < 4)
                        $display("FAIL %0s: pixel %0d = %x, want %x  (src=%0d dst=%0d w=%0d h=%0d sst=%0d dst_st=%0d op=%0d fill=%0d trans=%0d)",
                                 what, n, word[(n & 7)*4 +: 4], refp[n],
                                 src, dst, w, h, sst, dst_st, op, fmode, tmode);
                    bad = bad + 1;
                end
            end
            if (bad != 0) begin
                errors = errors + 1;
                // resynchronise so one failure does not cascade
                for (n = 0; n < PIXELS; n = n + 1) begin
                    word = mem.mem[n >> 3];
                    refp[n] = word[(n & 7)*4 +: 4];
                end
            end
            tests = tests + 1;
        end
    endtask

    // Lowest and highest pixel a (base, stride, w, h) rectangle touches.
    task extent(input integer base, input integer st, output integer elo, output integer ehi);
        begin
            elo = base; ehi = base + w - 1;
            if (st < 0) elo = base + (h - 1) * st;
            else        ehi = base + (h - 1) * st + w - 1;
        end
    endtask

    integer slo, shi, dlo, dhi, seed;
    localparam integer LIMIT = PIXELS - 2048 - 1;    // keep clear of the reader

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        for (i = 0; i < WORDS; i = i + 1) begin
            mem.mem[i] = (i >= QUIET) ? ~i : $random(seed);
            word = mem.mem[i];
            for (n = 0; n < 8; n = n + 1) refp[i*8 + n] = word[n*4 +: 4];
        end

        repeat (5) @(posedge clk); rst_n = 1;
        wait (idone); repeat (5) @(posedge clk);
        run_reader = 1;

        // ---- directed: the cases worth naming ----
        // A plain aligned copy.
        src = 1024; dst = 4096; sst = 640; dst_st = 640; w = 64; h = 3;
        op = 3; fill = 0; key = 0; fmode = 0; tmode = 0;
        model; run_blit; check("aligned copy");

        // One pixel, mid-word.
        src = 1027; dst = 9005; w = 1; h = 1;
        model; run_blit; check("single pixel");

        // The whole width.
        src = 20000; dst = 40000; sst = 1024; dst_st = 1024; w = 1024; h = 2;
        model; run_blit; check("1024 wide");
        $display("1024 x 2 copy: %0d cycles (%0d per pixel x100)", t_cyc, t_cyc * 100 / 2048);

        // Overlap, shifted right by three pixels on the same lines.
        src = 50000; dst = 50003; sst = 640; dst_st = 640; w = 200; h = 4;
        model; run_blit; check("overlap right");

        // Scroll up by a line: overlapping, top down.
        src = 60640; dst = 60000; sst = 640; dst_st = 640; w = 640; h = 5;
        model; run_blit; check("scroll up");

        // Scroll down by a line: overlapping, so bottom up.
        src = 60000 + 4*640; dst = 60640 + 4*640; sst = -640; dst_st = -640; w = 640; h = 5;
        model; run_blit; check("scroll down");

        // Fill, XOR and a transparent copy.
        dst = 70001; dst_st = 640; w = 77; h = 3; fmode = 1; fill = 9;
        model; run_blit; check("fill");
        op = 6; fill = 15;
        model; run_blit; check("xor fill");
        src = 1024; dst = 70010; sst = 640; w = 300; h = 2; fmode = 0; op = 3; tmode = 1; key = 5;
        model; run_blit; check("transparent");

        // Nothing to do.
        w = 0; h = 3; tmode = 0;
        wr16(5'h0C, 16'd0); wr(5'h12, 8'h01);
        repeat (20) @(posedge clk);
        if (busy) begin $display("FAIL: zero-width blit hung"); errors = errors + 1; end
        check("zero width");
        $display("directed: %0d test(s), %0d failed", tests, errors);

        // ---- random ----
        for (i = 0; i < 400; i = i + 1) begin
            ok = 0; tries = 0;
            while (!ok) begin
                w      = ($random(seed) & 1) ? 1 + ({$random(seed)} % 40)
                                             : 1 + ({$random(seed)} % 300);
                h      = 1 + ({$random(seed)} % 5);
                sst    = ($random(seed) % 800);
                dst_st = ($random(seed) % 800);
                src    = {$random(seed)} % LIMIT;
                // near the source often, so that overlaps actually happen
                dst    = ($random(seed) & 1) ? {$random(seed)} % LIMIT
                                             : src + ($random(seed) % 700);
                extent(src, sst, slo, shi);
                extent(dst, dst_st, dlo, dhi);
                ok = (slo >= 0 && shi < LIMIT && dlo >= 0 && dhi < LIMIT);
                tries = tries + 1;
            end
            op    = {$random(seed)} % 16;
            fill  = {$random(seed)} % 16;
            key   = {$random(seed)} % 16;
            fmode = ({$random(seed)} % 4) == 0;
            tmode = ({$random(seed)} % 3) == 0;
            // Destination lines that overlap each other, or source lines that
            // a previous line's writes reach, are legal and the model handles
            // them in the same line order the hardware uses.
            model; run_blit; check("random");
        end

        run_reader = 0;
        $display("random: %0d blit(s) in all, %0d failed", tests, errors);
        $display("competing reader: %0d burst(s), %0d bad", c_count, c_errors);
        if (c_count < tests) begin
            $display("FAIL: the reader was starved"); errors = errors + 1;
        end
        if (c_errors != 0) errors = errors + 1;
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end

    initial begin #4_000_000_000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
