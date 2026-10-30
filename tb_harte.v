//============================================================================
// tb_harte.v -- run SingleStepTests (TomHarte) 65816 vectors against the core
//
// Usage: vvp sim_harte +vectors=<file.hex> [+maxprint=N]
//
// The vector file (built by harte_run.py from the JSON) is a flat byte
// stream, $readmemh format, one byte per line:
//   u32  test count
//   per test:
//     initial regs: pc(2) s(2) p(1) a(2) x(2) y(2) dbr(1) d(2) pbr(1) e(1)
//     final   regs: same 16 bytes
//     u16 n_initial_ram, u16 n_final_ram
//     n_initial_ram x { addr(3) val(1) }
//     n_final_ram   x { addr(3) val(1) }
// (all little-endian)
//
// Only final architectural state is compared (registers + RAM); the core is
// intentionally not cycle accurate, so per-cycle bus activity is ignored.
//============================================================================
`timescale 1ns/1ps

module tb_harte;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [23:0] addr;
    wire [7:0]  wdata;
    wire        we, vld;

    reg [7:0] mem [0:16777215];        // full 16 MB
    wire [7:0] rdata = mem[addr];
    wire [23:0] wa = {addr[23:2], 2'b00};
    wire [31:0] rdata32 = {mem[wa | 24'd3], mem[wa | 24'd2], mem[wa | 24'd1], mem[wa]};

    cpu_65c816 dut (
        .clk(clk), .rst_n(rst_n),
        .addr(addr), .wdata(wdata), .rdata(rdata), .rdata32(rdata32), .r32(1'b1),
        .we(we), .vld(vld), .rdy(1'b1),
        .irq_n(1'b1), .nmi_n(1'b1), .abort_n(1'b1),
        .vpa(), .vda(), .vpb_n(), .mlb_n(),
        .e_flag(), .m_flag(), .x_flag(), .stopped()
    );

    // log CPU writes so memory can be scrubbed between tests
    reg [23:0] wlog [0:255];
    integer wn;
    always @(posedge clk) begin
        if (rst_n && vld && we) begin
            mem[addr] <= wdata;
            if (wn < 256) wlog[wn] = addr;
            wn = wn + 1;
        end
    end

    //------------------------------------------------------------------
    reg [7:0] tdat [0:4194303];
    integer cur;

    task get8(output [7:0] v);
        begin v = tdat[cur]; cur = cur + 1; end
    endtask
    task get16(output [15:0] v);
        begin v = {tdat[cur+1], tdat[cur]}; cur = cur + 2; end
    endtask
    task get24(output [23:0] v);
        begin v = {tdat[cur+2], tdat[cur+1], tdat[cur]}; cur = cur + 3; end
    endtask

    reg [15:0] i_pc, i_s, i_a, i_x, i_y, i_d;
    reg [7:0]  i_p, i_dbr, i_pbr, i_e;
    reg [15:0] f_pc, f_s, f_a, f_x, f_y, f_d;
    reg [7:0]  f_p, f_dbr, f_pbr, f_e;
    reg [15:0] n_ini, n_fin;
    reg [23:0] ia [0:255];
    reg [23:0] fa [0:255];
    reg [7:0]  fv [0:255];

    task get_regs;
        begin
            get16(i_pc); get16(i_s); get8(i_p); get16(i_a); get16(i_x);
            get16(i_y); get8(i_dbr); get16(i_d); get8(i_pbr); get8(i_e);
        end
    endtask

    wire [7:0] p_now = {dut.fN, dut.fV, dut.fM, dut.fX,
                        dut.fD, dut.fI, dut.fZ, dut.fC};

    reg [1023:0] fname;
    integer ntests, t, i, cyc, pass, fail, nprint, maxprint, dummy;
    reg done, ok, ram_ok, started;
    reg [7:0] b;

    initial begin
        if (!$value$plusargs("vectors=%s", fname)) begin
            $display("ERROR: +vectors=<file> required");
            $finish;
        end
        maxprint = 5;
        dummy = $value$plusargs("maxprint=%d", maxprint);

        for (i = 0; i < 16777216; i = i + 1) mem[i] = 8'h00;
        $readmemh(fname, tdat);

        rst_n = 0;
        repeat (2) @(negedge clk);
        rst_n = 1;

        cur = 0;
        get16(n_ini); get16(n_fin);          // u32 test count
        ntests = {n_fin, n_ini};
        pass = 0; fail = 0; nprint = 0;

        for (t = 0; t < ntests; t = t + 1) begin
            get_regs;
            get16(f_pc); get16(f_s); get8(f_p); get16(f_a); get16(f_x);
            get16(f_y); get8(f_dbr); get16(f_d); get8(f_pbr); get8(f_e);
            get16(n_ini); get16(n_fin);
            for (i = 0; i < n_ini; i = i + 1) begin
                get24(ia[i]); get8(b);
                mem[ia[i]] = b;
            end
            for (i = 0; i < n_fin; i = i + 1) begin
                get24(fa[i]); get8(fv[i]);
            end

            // deposit initial state. In emulation mode the chip hardwires
            // the stack to page 1 (SH=$01) and forces 8-bit index high bytes
            // to 0; the vectors put don't-care garbage in those high bytes
            // and expect the chip to normalize, so we deposit normalized
            // architectural state.
            @(negedge clk);
            dut.PC  = i_pc;  dut.A = i_a;   dut.D = i_d;
            dut.DBR = i_dbr; dut.PBR = i_pbr;
            dut.fN = i_p[7]; dut.fV = i_p[6]; dut.fM = i_p[5];
            dut.fX = i_p[4]; dut.fD = i_p[3]; dut.fI = i_p[2];
            dut.fZ = i_p[1]; dut.fC = i_p[0]; dut.fE = i_e[0];
            if (i_e[0]) begin
                dut.S = {8'h01, i_s[7:0]};
                dut.X = {8'h00, i_x[7:0]};
                dut.Y = {8'h00, i_y[7:0]};
            end else begin
                dut.S = i_s;
                dut.X = i_p[4] ? {8'h00, i_x[7:0]} : i_x;
                dut.Y = i_p[4] ? {8'h00, i_y[7:0]} : i_y;
            end
            dut.xb = 1'b0;                     // banked mode off
            dut.state = 5'd0;                 // S_FETCH
            dut.nmi_pend = 1'b0;
            dut.irq1 = 1'b1; dut.irq2 = 1'b1;
            dut.nmi1 = 1'b1; dut.nmi2 = 1'b1;
            dut.xp = 1'b0; dut.lp = 1'b0; dut.snap_late = 1'b0;
            dut.q = 64'h0; dut.qn = 4'd0; dut.fa = i_pc; dut.fbusy = 1'b0; dut.fdrop = 1'b0;
            wn = 0;

            // run one instruction
            // The instruction has begun once the state leaves S_FETCH or PC
            // moves (an implied opcode stays in S_FETCH): the queue starts
            // empty, so the first cycles only fill it.
            done = 0; cyc = 0; started = 0;
            while (!done && cyc < 200) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
                if (dut.state != 5'd0 || dut.PC !== i_pc) started = 1;
                if (started && (dut.state == 5'd0 || dut.state == 5'd19
                                || dut.state == 5'd20))        // FETCH/WAI/STP
                    done = 1;
            end
            // A read's or an implied opcode's execute is deferred to the
            // next fetch cycle (xp, lp): run it, as the bubble the core
            // inserts before a pull.
            if (done && dut.state == 5'd0 && (dut.xp || dut.lp)) begin
                force dut.fetch_pull = 1'b1;
                @(posedge clk); #1;
                release dut.fetch_pull;
            end

            // compare
            ok = done
                 && (dut.PC === f_pc) && (dut.S === f_s) && (dut.A === f_a)
                 && (dut.X === f_x) && (dut.Y === f_y) && (dut.D === f_d)
                 && (dut.DBR === f_dbr) && (dut.PBR === f_pbr)
                 && (p_now === f_p) && (dut.fE === f_e[0]);
            ram_ok = 1;
            for (i = 0; i < n_fin; i = i + 1)
                if (mem[fa[i]] !== fv[i]) ram_ok = 0;

            if (ok && ram_ok) pass = pass + 1;
            else begin
                fail = fail + 1;
                if (nprint < maxprint) begin
                    nprint = nprint + 1;
                    $display("MISMATCH test %0d (cyc=%0d done=%b)", t, cyc, done);
                    $display("  exp pc=%h s=%h a=%h x=%h y=%h d=%h dbr=%h pbr=%h p=%b e=%b",
                             f_pc, f_s, f_a, f_x, f_y, f_d, f_dbr, f_pbr, f_p, f_e[0]);
                    $display("  got pc=%h s=%h a=%h x=%h y=%h d=%h dbr=%h pbr=%h p=%b e=%b",
                             dut.PC, dut.S, dut.A, dut.X, dut.Y, dut.D,
                             dut.DBR, dut.PBR, p_now, dut.fE);
                    if (!ram_ok)
                        for (i = 0; i < n_fin; i = i + 1)
                            if (mem[fa[i]] !== fv[i])
                                $display("  ram[%h] exp %h got %h",
                                         fa[i], fv[i], mem[fa[i]]);
                end
            end

            // scrub memory
            for (i = 0; i < n_ini; i = i + 1) mem[ia[i]] = 8'h00;
            for (i = 0; i < n_fin; i = i + 1) mem[fa[i]] = 8'h00;
            for (i = 0; i < wn && i < 256; i = i + 1) mem[wlog[i]] = 8'h00;
        end

        $display("RESULT %0d %0d", pass, fail);
        $finish;
    end

endmodule
