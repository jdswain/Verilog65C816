//============================================================================
// tb_sdram_burst.v -- exercise the burst controller against the SDRAM model.
//
// Checks burst reads return four correct words, single-word writes with byte
// masks do not disturb neighbours, row hits are actually cheaper than row
// misses, and port 0 wins arbitration against port 1.
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_sdram_burst;
    localparam integer FREQ = 27_000_000;

    reg clk = 1'b0; always #18.5 clk = ~clk;
    reg rst_n = 1'b0;

    reg         p0_req = 0, p0_we = 0;
    reg  [20:0] p0_addr = 0;
    reg  [31:0] p0_wdata = 0;
    reg  [3:0]  p0_wmask = 4'hF;
    wire        p0_done, p0_rvalid;

    reg         p1_req = 0, p1_we = 0;
    reg  [20:0] p1_addr = 0;
    reg  [31:0] p1_wdata = 0;
    reg  [3:0]  p1_wmask = 4'hF;
    wire        p1_done, p1_rvalid;

    wire [31:0] rdata;
    wire        init_done;

    wire [10:0] sa; wire [1:0] sba; wire [3:0] sdqm; wire [31:0] sdq;
    wire scs_n, sras_n, scas_n, swe_n, scke;

    sdram_burst #(.FREQ(FREQ)) dut (
        .clk(clk), .rst_n(rst_n),
        .p0_req(p0_req), .p0_we(p0_we), .p0_addr(p0_addr),
        .p0_wdata(p0_wdata), .p0_wmask(p0_wmask),
        .p0_done(p0_done), .p0_rvalid(p0_rvalid),
        .p1_req(p1_req), .p1_we(p1_we), .p1_addr(p1_addr),
        .p1_wdata(p1_wdata), .p1_wmask(p1_wmask),
        .p1_done(p1_done), .p1_rvalid(p1_rvalid),
        .p2_req(1'b0), .p2_we(1'b0), .p2_addr(21'd0), .p2_wdata(32'd0),
        .p2_wmask(4'd0), .p2_done(), .p2_rvalid(),
        .rdata(rdata), .init_done(init_done),
        .sdram_a(sa), .sdram_ba(sba), .sdram_dq(sdq), .sdram_dqm(sdqm),
        .sdram_cs_n(scs_n), .sdram_ras_n(sras_n), .sdram_cas_n(scas_n),
        .sdram_we_n(swe_n), .sdram_cke(scke)
    );

    sdram_model #(.MEM_WORDS(32768), .CAS(2)) mem (
        .clk(~clk), .cke(scke), .cs_n(scs_n),
        .ras_n(sras_n), .cas_n(scas_n), .we_n(swe_n),
        .a(sa), .ba(sba), .dqm(sdqm), .dq(sdq)
    );

    integer errors = 0;
    integer t0, t1;
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    // --- port 1 helpers ---
    task p1_write(input [20:0] a, input [31:0] d, input [3:0] m);
        begin
            @(negedge clk);
            p1_addr = a; p1_wdata = d; p1_wmask = m; p1_we = 1; p1_req = 1;
            @(posedge p1_done); @(negedge clk);
            p1_req = 0; p1_we = 0;
        end
    endtask

    reg [31:0] burst [0:3];
    integer bi;

    task p1_read_burst(input [20:0] a);
        begin
            bi = 0;
            @(negedge clk);
            p1_addr = a; p1_we = 0; p1_req = 1;
            t0 = cyc;
            while (bi < 4) begin
                @(posedge clk);
                if (p1_rvalid) begin burst[bi] = rdata; bi = bi + 1; end
            end
            @(posedge p1_done);
            t1 = cyc;
            @(negedge clk);
            p1_req = 0;
        end
    endtask

    task expect_word(input integer i, input [31:0] want);
        begin
            if (burst[i] !== want) begin
                $display("FAIL: burst word %0d = %08x, want %08x", i, burst[i], want);
                errors = errors + 1;
            end
        end
    endtask

    integer miss_cycles, hit_cycles;
    integer i;

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        wait (init_done);
        repeat (5) @(posedge clk);

        // ---- fill four consecutive words, then burst-read them ----
        for (i = 0; i < 4; i = i + 1)
            p1_write(i[20:0], 32'h1000_0000 + i, 4'hF);
        p1_read_burst(21'd0);
        expect_word(0, 32'h1000_0000);
        expect_word(1, 32'h1000_0001);
        expect_word(2, 32'h1000_0002);
        expect_word(3, 32'h1000_0003);
        $display("burst read:      %0d error(s)", errors);

        // ---- byte masking must not disturb neighbours ----
        p1_write(21'd1, 32'hAABBCCDD, 4'b0010);      // only byte 1
        p1_read_burst(21'd0);
        expect_word(1, 32'h1000_CC01);
        $display("byte mask:       %0d error(s)", errors);

        // ---- row hit should be cheaper than a row miss ----
        p1_read_burst(21'd0);                        // row 0 now open
        hit_cycles = t1 - t0;
        p1_read_burst(21'h00400);                    // different row, same bank
        miss_cycles = t1 - t0;
        $display("row hit %0d cycles, row miss %0d cycles", hit_cycles, miss_cycles);
        if (hit_cycles >= miss_cycles) begin
            $display("FAIL: open-row optimisation is not working");
            errors = errors + 1;
        end

        // ---- port 0 must win arbitration ----
        p0_addr = 21'd0; p0_we = 0;
        @(negedge clk);
        p1_addr = 21'h00800; p1_we = 0; p1_req = 1; p0_req = 1;
        @(posedge clk);
        while (!p0_done && !p1_done) @(posedge clk);
        if (!p0_done) begin
            $display("FAIL: port 1 was served before port 0");
            errors = errors + 1;
        end else begin
            $display("arbitration:     port 0 served first");
        end
        @(negedge clk); p0_req = 0;
        @(posedge p1_done); @(negedge clk); p1_req = 0;

        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #4_000_000;
        $display("TIMEOUT (init_done=%b state=%0d)", init_done, dut.state);
        $finish;
    end
endmodule

`default_nettype wire
