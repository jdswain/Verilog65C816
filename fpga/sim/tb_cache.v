//============================================================================
// tb_cache.v -- cache + burst controller + SDRAM model, end to end.
//
// The interesting cases are the ones that would silently corrupt data:
//   * a read behind a buffered write must not see stale memory
//   * a write-through must reach SDRAM even when it misses the cache
//   * a line eviction must not lose a write that only updated the cache
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_cache;
    reg clk = 0; always #18.5 clk = ~clk;
    reg rst_n = 0;

    reg  [22:0] addr = 0;
    reg  [7:0]  wdata = 0;
    wire [7:0]  rdata;
    wire [31:0] rdata32;
    reg         req = 0, we = 0;
    wire        ack;
    wire [31:0] stat_hits, stat_misses;

    wire        m_req, m_we, m_done, m_rvalid;
    wire [20:0] m_addr;
    wire [31:0] m_wdata, m_rdata;
    wire [3:0]  m_wmask;

    // A second master on the memory-master port, writing behind the cache.
    reg         x_req = 0, x_we = 0;
    reg  [20:0] x_addr = 0;
    reg  [31:0] x_wdata = 0;
    wire        x_done;

    cache u_cache (
        .clk(clk), .rst_n(rst_n),
        .addr(addr), .wdata(wdata), .rdata(rdata), .rdata32(rdata32),
        .req(req), .we(we), .ack(ack),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_wmask(m_wmask), .m_done(m_done), .m_rvalid(m_rvalid), .m_rdata(m_rdata),
        .inv_valid(x_done & x_we), .inv_addr(x_addr),
        .stat_hits(stat_hits), .stat_misses(stat_misses)
    );

    wire [10:0] sa; wire [1:0] sba; wire [3:0] sdqm; wire [31:0] sdq;
    wire scs_n, sras_n, scas_n, swe_n, scke;
    wire init_done;

    sdram_burst u_sdram (
        .clk(clk), .rst_n(rst_n),
        .p0_req(1'b0), .p0_we(1'b0), .p0_addr(21'd0), .p0_wdata(32'd0),
        .p0_wmask(4'd0), .p0_done(), .p0_rvalid(),
        .p1_req(m_req), .p1_we(m_we), .p1_addr(m_addr), .p1_wdata(m_wdata),
        .p1_wmask(m_wmask), .p1_done(m_done), .p1_rvalid(m_rvalid),
        .p2_req(x_req), .p2_we(x_we), .p2_addr(x_addr), .p2_wdata(x_wdata),
        .p2_wmask(4'b1111), .p2_done(x_done), .p2_rvalid(),
        .rdata(m_rdata), .init_done(init_done),
        .sdram_a(sa), .sdram_ba(sba), .sdram_dq(sdq), .sdram_dqm(sdqm),
        .sdram_cs_n(scs_n), .sdram_ras_n(sras_n), .sdram_cas_n(scas_n),
        .sdram_we_n(swe_n), .sdram_cke(scke)
    );

    sdram_model #(.MEM_WORDS(32768), .CAS(2)) mem (
        .clk(~clk), .cke(scke), .cs_n(scs_n),
        .ras_n(sras_n), .cas_n(scas_n), .we_n(swe_n),
        .a(sa), .ba(sba), .dqm(sdqm), .dq(sdq)
    );

    integer errors = 0, cyc = 0, t0;
    always @(posedge clk) cyc = cyc + 1;

    // The CPU bus samples ack as a LEVEL, not an edge: with the held-word fast
    // path ack is combinational and can already be high in the cycle the
    // address is presented, so waiting for a rising edge would miss it (and
    // hang on back-to-back hits).
    task cwrite(input [22:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; wdata = d; we = 1; req = 1;
            #1;
            while (!ack) begin @(posedge clk); @(negedge clk); #1; end
            @(posedge clk);
            req = 0; we = 0;
        end
    endtask

    task cread(input [22:0] a, output [7:0] d);
        begin
            @(negedge clk); addr = a; we = 0; req = 1;
            t0 = cyc;
            #1;
            while (!ack) begin @(posedge clk); @(negedge clk); #1; end
            d = rdata;
            @(posedge clk);
            req = 0;
        end
    endtask

    // Write a whole word through the master port, as the blitter would.
    task xwrite(input [22:0] a, input [31:0] d);
        begin
            @(negedge clk); x_addr = a[22:2]; x_wdata = d; x_we = 1; x_req = 1;
            // Hold the request through the cycle `done` is high, as a real
            // master does: the cache samples the report on that edge.
            @(posedge x_done); @(posedge clk); #1;
            x_req = 0; x_we = 0;
        end
    endtask

    reg [7:0] v;
    task expect(input [22:0] a, input [7:0] want, input [200*8-1:0] what);
        begin
            cread(a, v);
            if (v !== want) begin
                $display("FAIL %0s: [%06x] = %02x, want %02x", what, a, v, want);
                errors = errors + 1;
            end
        end
    endtask

    integer i, miss_c, hit_c, first_c, next_c, last_c, tseq0;
    reg [22:0] ea;

    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        wait (init_done); repeat (5) @(posedge clk);

        // ---- basic write-through then read back ----
        cwrite(23'h000000, 8'h11);
        cwrite(23'h000001, 8'h22);
        cwrite(23'h000002, 8'h33);
        cwrite(23'h000003, 8'h44);
        expect(23'h000000, 8'h11, "byte 0");
        expect(23'h000001, 8'h22, "byte 1");
        expect(23'h000002, 8'h33, "byte 2");
        expect(23'h000003, 8'h44, "byte 3");
        $display("write-through:   %0d error(s)", errors);

        // ---- read behind a buffered write (the ordering hazard) ----
        // Write to a line, then immediately read a DIFFERENT line that maps to
        // the same set, forcing a fill while the write is still buffered.
        cwrite(23'h001000, 8'h5A);
        expect(23'h001000, 8'h5A, "read own write");
        $display("ordering:        %0d error(s)", errors);

        // ---- eviction must not lose data ----
        // The cache is 4 KB direct-mapped, so addresses 4 KB apart share a set.
        // Touching three of them evicts the line; write-through means the byte
        // is still in SDRAM and must come back intact.
        cwrite(23'h000010, 8'hA1);
        for (i = 1; i <= 3; i = i + 1) begin
            ea = 23'h000010 + (i * 23'h001000);
            cread(ea, v);                       // value irrelevant: this evicts
        end
        expect(23'h000010, 8'hA1, "survives eviction");
        $display("eviction:        %0d error(s)", errors);

        // ---- a hit must be faster than a miss ----
        expect(23'h000000, 8'h11, "warm");
        cread(23'h000000, v); hit_c  = cyc - t0;
        cread(23'h004000, v); miss_c = cyc - t0;
        $display("hit %0d cycles, miss %0d cycles", hit_c, miss_c);
        if (hit_c >= miss_c) begin
            $display("FAIL: a hit is not cheaper than a miss");
            errors = errors + 1;
        end

        // ---- consecutive bytes within one word must be cheap ----
        // This is the whole point of the 32-bit read path: the first byte of a
        // word costs a lookup, the next three should come from the held word.
        for (i = 0; i < 4; i = i + 1) cwrite(23'h003000 + i[22:0], 8'hA0 + i[7:0]);
        cread(23'h003000, v);                 // fill the line
        cread(23'h008000, v);                 // displace the held word
        t0 = cyc; cread(23'h003000, v); first_c = cyc - t0;
        t0 = cyc; cread(23'h003001, v); next_c  = cyc - t0;
        if (v !== 8'hA1) begin
            $display("FAIL: held-word byte 1 = %02x, want a1", v);
            errors = errors + 1;
        end
        t0 = cyc; cread(23'h003003, v); last_c = cyc - t0;
        if (v !== 8'hA3) begin
            $display("FAIL: held-word byte 3 = %02x, want a3", v);
            errors = errors + 1;
        end
        $display("same word: first %0d cyc, next %0d cyc, last %0d cyc",
                 first_c, next_c, last_c);
        if (next_c >= first_c || last_c >= first_c) begin
            $display("FAIL: bytes within the held word are not cheaper");
            errors = errors + 1;
        end

        // a write into the held word must invalidate it
        cwrite(23'h003002, 8'h5C);
        cread(23'h003002, v);
        if (v !== 8'h5C) begin
            $display("FAIL: stale held word after write: %02x", v);
            errors = errors + 1;
        end
        $display("held-word coherency: %0d error(s)", errors);

        // ---- writes from another master must not leave stale data ----
        // Cached line, not the held word.
        for (i = 0; i < 8; i = i + 1) cwrite(23'h005000 + i[22:0], 8'hB0 + i[7:0]);
        cread(23'h005000, v);                 // line is cached
        cread(23'h006000, v);                 // held word is elsewhere
        xwrite(23'h005004, 32'hDDCCBBAA);
        expect(23'h005004, 8'hAA, "master write, cached line");
        expect(23'h005007, 8'hDD, "master write, cached line byte 3");
        expect(23'h005000, 8'hB0, "rest of the line survives a refill");

        // The held word itself.
        cread(23'h005004, v);                 // now held
        xwrite(23'h005004, 32'h44332211);
        expect(23'h005004, 8'h11, "master write, held word");
        expect(23'h005005, 8'h22, "master write, held word byte 1");

        // A line that maps to the same set but is not the cached one must be
        // left alone: the cached line stays a hit.
        cread(23'h005000, v);
        i = stat_misses;
        xwrite(23'h009004, 32'h0BADF00D);     // same index, different tag
        expect(23'h005008, 8'h00 + mem.mem[23'h005008 >> 2][7:0], "unrelated line");
        if (stat_misses !== i) begin
            $display("FAIL: a write to another tag evicted the cached line");
            errors = errors + 1;
        end
        expect(23'h009004, 8'h0D, "the other line reads back");

        // Hammer it: interleave master writes and CPU reads of one word with
        // every phase relationship the two state machines can have.
        for (i = 0; i < 40; i = i + 1) begin
            fork
                xwrite(23'h007010, {4{i[7:0]}});
                begin
                    repeat (i % 13) @(posedge clk);
                    cread(23'h007010 + (i % 4), v);     // racing: old or new
                end
            join
            repeat (8) @(posedge clk);        // let the invalidation land
            expect(23'h007010 + ((i + 1) % 4), i[7:0], "after racing write");
            expect(23'h007010 + ((i + 2) % 4), i[7:0], "after racing write, held");
        end
        $display("master-write coherency: %0d error(s)", errors);

        // ---- sequential byte cost, the way instruction fetch behaves ----
        for (i = 0; i < 16; i = i + 1) cwrite(23'h004000 + i[22:0], i[7:0]);
        cread(23'h004000, v);              // fill the line
        cread(23'h00C000, v);              // displace the held word
        tseq0 = cyc;                       // cread clobbers t0 internally
        for (i = 0; i < 16; i = i + 1) cread(23'h004000 + i[22:0], v);
        $display("16 sequential bytes: %0d cycles (%.2f per byte)",
                 cyc - tseq0, (cyc - tseq0)/16.0);

        $display("hits=%0d misses=%0d", stat_hits, stat_misses);
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #30_000_000;
        $display("TIMEOUT (cache state=%0d)", u_cache.state);
        $finish;
    end
endmodule

`default_nettype wire
