// tb_dma.v -- the DMA engine (dma.v) with the bridge (external_bus.v) and
// port 2's arbiter (mm_mux.v), against a model of port 2's memory, a
// 74HCT138 on the select code, and models of the two chips:
//
//   an 82077AA (channel 1, slot 1): a 16-byte FIFO that a read fills one
//     byte every BYTE_T clocks and that overruns if the engine falls behind;
//     DRQ while it has a byte (a write: while it has room), and slow to
//     drop it: 3 clocks (119 ns) after the strobe rises, which the engine's
//     hold-off must cover.
//   a 53C80 (channel 0, slot 4): DRQ cleared by /DACK falling and raised
//     again a few clocks after the strobe; it can change phase partway,
//     after which it asks for nothing more.
//
// A second master writes on port 2 throughout, as the blitter would. The
// checks: bytes land where they should and nowhere else (unaligned starts
// and ends), TC on the last byte only and only with /DACK, DONE and the
// interrupt, a stop partway with ADDR and COUNT read back, both channels at
// once with no FIFO overrun, a CPU cycle in the middle of a transfer, a
// read held off while the cache has a store in flight, registers that do
// not change while BUSY, and COUNT = 0.
//
//   iverilog -g2005 -o tb_dma rtl/dma.v rtl/mm_mux.v rtl/external_bus.v sim/tb_dma.v && vvp tb_dma
`timescale 1ns/1ps
`default_nettype none

module tb_dma;
    reg clk = 0, rst_n = 0;
    always #(500.0/25.2) clk = ~clk;

    integer errors = 0;
    task check(input [255:0] name, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %h expected %h", name, got, exp);
            errors = errors + 1;
        end else $display("  ok  %0s = %h", name, got);
    endtask

    //------------------------------------------------------------------
    // The engine, the bridge and the arbiter
    //------------------------------------------------------------------
    reg  [4:0] r_addr; reg [7:0] r_wdata; reg r_cs, r_we;
    wire [7:0] r_rdata; wire irq;
    reg  wr_busy;

    wire       bq, bwe, btc, back; wire [2:0] bslot; wire [7:0] bwd, bus_rdata;
    wire       dm_req, dm_we, dm_done, dm_rvalid; wire [20:0] dm_addr;
    wire [31:0] dm_wdata; wire [3:0] dm_wmask;
    wire       p_req, p_we, p_done, p_rvalid; wire [20:0] p_addr;
    wire [31:0] p_wdata; wire [3:0] p_wmask;
    reg  [31:0] p_rdata;
    reg        bl_req, bl_we; reg [20:0] bl_addr; reg [31:0] bl_wdata;
    wire       bl_done, bl_rvalid;
    wire [1:0] drq;

    dma u_dma (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(r_addr), .wdata(r_wdata), .rdata(r_rdata),
        .cs(r_cs), .we(r_we), .irq(irq),
        .drq(drq),
        .b_req(bq), .b_we(bwe), .b_slot(bslot), .b_tc(btc), .b_wdata(bwd),
        .b_rdata(bus_rdata), .b_ack(back),
        .m_req(dm_req), .m_we(dm_we), .m_addr(dm_addr),
        .m_wdata(dm_wdata), .m_wmask(dm_wmask),
        .m_done(dm_done), .m_rvalid(dm_rvalid), .m_rdata(p_rdata),
        .wr_busy(wr_busy)
    );

    mm_mux u_mux (
        .clk(clk), .rst_n(rst_n),
        .b_req(bl_req), .b_we(bl_we), .b_addr(bl_addr),
        .b_wdata(bl_wdata), .b_wmask(4'hF),
        .b_done(bl_done), .b_rvalid(bl_rvalid),
        .d_req(dm_req), .d_we(dm_we), .d_addr(dm_addr),
        .d_wdata(dm_wdata), .d_wmask(dm_wmask),
        .d_done(dm_done), .d_rvalid(dm_rvalid),
        .p_req(p_req), .p_we(p_we), .p_addr(p_addr),
        .p_wdata(p_wdata), .p_wmask(p_wmask),
        .p_done(p_done), .p_rvalid(p_rvalid)
    );

    reg  [10:0] c_addr; reg [7:0] c_wdata; reg c_req, c_we;
    wire        c_ack;
    wire [3:0]  ext_a; wire [7:0] d_out; wire d_oe;
    wire [2:0]  sel; wire sel_en_n, rd_n, wr_n, res_n, tc;
    reg  [7:0]  d_in;

    external_bus u_bus (
        .clk(clk), .rst_n(rst_n),
        .addr(c_addr), .wdata(c_wdata), .rdata(bus_rdata),
        .req(c_req), .we(c_we), .ack(c_ack),
        .dma_req(bq), .dma_we(bwe), .dma_slot(bslot), .dma_tc(btc),
        .dma_wdata(bwd), .dma_ack(back),
        .card_reset(1'b0), .irq(),
        .ext_a(ext_a), .ext_d_in(d_in), .ext_d_out(d_out), .ext_d_oe(d_oe),
        .ext_sel(sel), .ext_sel_en_n(sel_en_n),
        .ext_rd_n(rd_n), .ext_wr_n(wr_n), .ext_tc(tc),
        .ext_res_n(res_n), .ext_irq_n(1'b1)
    );

    wire [7:0] cs_n = sel_en_n ? 8'hFF : ~(8'd1 << sel);

    //------------------------------------------------------------------
    // Port 2's memory: 64 KB. A transaction starts some clocks after the
    // request (as if the CPU or the display had the controller), a read
    // returns four words, and `done` ends it; one idle cycle follows.
    //------------------------------------------------------------------
    reg [7:0] mem [0:65535];
    reg [2:0] pm_state; reg [3:0] pm_wait; reg [1:0] pm_beat;
    reg [20:0] pm_addr; reg pm_we;
    reg p_done_r, p_rvalid_r;
    assign p_done = p_done_r; assign p_rvalid = p_rvalid_r;
    integer pk, port_txns;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pm_state <= 0; p_done_r <= 0; p_rvalid_r <= 0; port_txns = 0;
        end else begin
            p_done_r <= 0; p_rvalid_r <= 0;
            case (pm_state)
            0: if (p_req) begin
                   pm_addr <= p_addr; pm_we <= p_we;
                   pm_wait <= 3 + ($random & 7); pm_state <= 1;
                   port_txns = port_txns + 1;
               end
            1: begin
                   if (p_addr !== pm_addr || p_we !== pm_we || !p_req) begin
                       $display("FAIL port 2 request changed mid-transaction at %0t", $time);
                       errors = errors + 1;
                   end
                   if (pm_wait != 0) pm_wait <= pm_wait - 1;
                   else if (pm_we) begin
                       for (pk = 0; pk < 4; pk = pk + 1)
                           if (p_wmask[pk]) mem[{pm_addr[13:0], 2'b00} + pk] <= p_wdata[pk*8 +: 8];
                       pm_state <= 3;
                   end else begin
                       pm_beat <= 0; pm_state <= 2;
                   end
               end
            2: begin
                   p_rdata <= {mem[{pm_addr[13:2], pm_beat, 2'b11}], mem[{pm_addr[13:2], pm_beat, 2'b10}],
                               mem[{pm_addr[13:2], pm_beat, 2'b01}], mem[{pm_addr[13:2], pm_beat, 2'b00}]};
                   p_rvalid_r <= 1;
                   pm_beat <= pm_beat + 1;
                   if (pm_beat == 3) pm_state <= 3;
               end
            3: begin p_done_r <= 1; pm_state <= 4; end
            4: pm_state <= 0;                       // the controller's S_GAP
            endcase
        end
    end

    // The other master: word writes to $F000-$FFFF, all the time it is on,
    // dropping its request for a cycle after each done.
    reg bl_on; reg [7:0] bl_n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin bl_req <= 0; bl_we <= 1; bl_addr <= 21'h3C00; bl_wdata <= 0; bl_n <= 0; end
        else if (bl_req) begin
            if (bl_done) begin
                bl_req <= 0; bl_n <= bl_n + 1;
                bl_addr <= 21'h3C00 + bl_n; bl_wdata <= {4{bl_n}};
            end
        end else if (bl_on) bl_req <= 1;
    end

    //------------------------------------------------------------------
    // The 82077AA: slot 1, channel 1
    //------------------------------------------------------------------
    integer BYTE_T = 40;
    reg        f_rd;                 // 1: a read (device to memory)
    integer    f_total, f_made, f_taken, f_tc_at, f_tc_bad, f_overrun, f_timer;
    reg [7:0]  f_fifo [0:15]; integer f_head, f_n;
    reg [7:0]  f_got [0:1023];
    wire f_dack = ~cs_n[1];
    integer f_late;                  // clocks DRQ lags behind a byte taken
    reg     f_drq_was;
    assign drq[1] = (f_late > 0) ? f_drq_was
                  : f_rd ? (f_n > 0) : (f_taken < f_total && f_n < 16);
    initial begin f_total = 0; f_made = 0; f_taken = 0; f_n = 0; f_head = 0;
                  f_tc_at = -1; f_tc_bad = 0; f_overrun = 0; f_timer = 0; f_rd = 1;
                  f_late = 0; f_drq_was = 0; end
    always @(posedge clk) if (f_late > 0) f_late = f_late - 1;
    always @(posedge clk) if (f_rd && f_made < f_total) begin
        if (f_timer >= BYTE_T) begin
            f_timer = 0;
            if (f_n == 16) f_overrun = f_overrun + 1;
            else begin f_fifo[(f_head + f_n) % 16] = 8'hA0 ^ f_made[7:0]; f_n = f_n + 1; end
            f_made = f_made + 1;
        end else f_timer = f_timer + 1;
    end
    always @(posedge rd_n) if (f_dack) begin
        f_drq_was = 1; f_late = 3;
        if (f_n == 0) begin $display("FAIL floppy read with its FIFO empty, %0t", $time); errors = errors + 1; end
        if (tc) f_tc_at = f_taken;
        f_head = (f_head + 1) % 16; f_n = f_n - 1; f_taken = f_taken + 1;
    end
    always @(posedge wr_n) if (f_dack) begin
        f_drq_was = 1; f_late = 3;
        if (f_taken >= f_total) begin $display("FAIL floppy written past its count, %0t", $time); errors = errors + 1; end
        if (tc) f_tc_at = f_taken;
        f_got[f_taken] = d_out; f_taken = f_taken + 1;
    end

    //------------------------------------------------------------------
    // The 53C80: slot 4, channel 0
    //------------------------------------------------------------------
    reg        s_rd;
    integer    s_total, s_stop, s_taken, s_tc_at, s_ready;
    reg [7:0]  s_got [0:1023];
    reg        s_drq;
    wire s_dack = ~cs_n[4];
    assign drq[0] = s_drq;
    initial begin s_total = 0; s_stop = 1 << 30; s_taken = 0; s_tc_at = -1;
                  s_drq = 0; s_rd = 1; s_ready = 0; end
    always @(negedge s_dack) s_drq = 0;             // /DACK clears DRQ
    always @(posedge rd_n) if (s_dack) begin
        if (tc) s_tc_at = s_taken; s_taken = s_taken + 1; s_ready = 5;
    end
    always @(posedge wr_n) if (s_dack) begin
        if (tc) s_tc_at = s_taken; s_got[s_taken] = d_out; s_taken = s_taken + 1; s_ready = 5;
    end
    always @(posedge clk) begin
        if (s_ready > 0) s_ready = s_ready - 1;
        else if (!s_dack && s_taken < s_total && s_taken < s_stop) s_drq = 1;
    end

    // Data on the bus during a read: whichever /DACK, or a register of slot 0.
    reg [7:0] card0 [0:15];
    always @* begin
        d_in = 8'hFF;
        if (!rd_n) begin
            if (f_dack)        d_in = f_fifo[f_head];
            else if (s_dack)   d_in = 8'h50 ^ s_taken[7:0];
            else if (!cs_n[0]) d_in = card0[ext_a];
        end
    end

    // TC is only ever high inside a /DACK cycle.
    always @(posedge tc) if (cs_n[1] && cs_n[4] && sel_en_n == 1'b0) begin
        $display("FAIL TC outside a /DACK cycle at %0t", $time); errors = errors + 1;
    end
    always @(negedge rd_n or negedge wr_n) if (tc && cs_n[1] && cs_n[4]) begin
        $display("FAIL TC with a strobe and no /DACK at %0t", $time); errors = errors + 1;
    end

    // While wr_busy is high the engine must not start a read.
    reg dm_req_d;
    always @(posedge clk) begin
        dm_req_d <= dm_req;
        if (wr_busy && dm_req && !dm_req_d && !dm_we) begin
            $display("FAIL a read started while the cache had a store in flight, %0t", $time);
            errors = errors + 1;
        end
    end

    //------------------------------------------------------------------
    task rw(input [4:0] a, input [7:0] d);
        begin
            @(negedge clk); r_addr = a; r_wdata = d; r_we = 1; r_cs = 1;
            @(negedge clk); r_cs = 0; r_we = 0;
        end
    endtask
    task rr(input [4:0] a, output [7:0] d);
        begin @(negedge clk); r_addr = a; #1 d = r_rdata; end
    endtask
    task setup(input ch, input [23:0] ad, input [23:0] n);
        begin
            rw({ch, 4'h0}, ad[7:0]);  rw({ch, 4'h1}, ad[15:8]);  rw({ch, 4'h2}, ad[23:16]);
            rw({ch, 4'h4}, n[7:0]);   rw({ch, 4'h5}, n[15:8]);   rw({ch, 4'h6}, n[23:16]);
        end
    endtask
    task wait_done(input ch, input integer limit);
        reg [7:0] st; integer t;
        begin
            t = 0; rr({ch, 4'h9}, st);
            while (!st[0] && t < limit) begin rr({ch, 4'h9}, st); t = t + 1; end
            if (!st[0]) begin $display("FAIL channel %0d never DONE", ch); errors = errors + 1; end
        end
    endtask
    task wait_idle(input ch);
        reg [7:0] st;
        begin rr({ch, 4'h9}, st); while (st[7]) rr({ch, 4'h9}, st); end
    endtask
    function [23:0] get24(input [7:0] a, input [7:0] b, input [7:0] c3);
        get24 = {c3, b, a};
    endfunction

    reg [7:0] v, v1, v2;
    integer i, bad, cyc0;

    initial begin
        $dumpfile("tb_dma.vcd"); $dumpvars(0, tb_dma);
        r_cs = 0; r_we = 0; r_addr = 0; r_wdata = 0; wr_busy = 0;
        c_req = 0; c_we = 0; c_addr = 0; c_wdata = 0; bl_on = 0;
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEE;
        for (i = 0; i < 16; i = i + 1) card0[i] = 8'h30 + i;
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (4) @(posedge clk);
        bl_on = 1;

        //--------------------------------------------------------------
        $display("-- floppy read: 515 bytes to $1003, TC, interrupt --");
        f_rd = 1; f_total = 515; f_made = 0; f_taken = 0; f_tc_at = -1;
        setup(1, 24'h001003, 24'd515);
        rw(5'h18, 8'h0D);                       // IE, TC, read, EN
        rr(5'h19, v); check("BUSY", v[7], 1'b1);
        rw(5'h10, 8'h55);                       // ADDR while BUSY: ignored
        wait_done(1, 200000);
        check("irq", irq, 1'b1);
        bad = 0;
        for (i = 0; i < 515; i = i + 1) if (mem[16'h1003 + i] !== (8'hA0 ^ i[7:0])) bad = bad + 1;
        check("bytes wrong", bad, 0);
        check("byte before", mem[16'h1002], 8'hEE);
        check("byte after", mem[16'h1003 + 515], 8'hEE);
        check("TC on the last byte", f_tc_at, 514);
        check("FIFO overruns", f_overrun, 0);
        rr(5'h10, v); rr(5'h11, v1); rr(5'h12, v2);
        check("ADDR at the end", get24(v, v1, v2), 24'h001003 + 515);
        rr(5'h14, v); rr(5'h15, v1); rr(5'h16, v2);
        check("COUNT at the end", get24(v, v1, v2), 0);
        rr(5'h18, v); check("CTRL: EN cleared", v, 8'h0C);
        rr(5'h19, v); check("STATUS: DONE, not BUSY", v & 8'h81, 8'h01);
        rw(5'h19, 8'h01);
        check("irq cleared", irq, 1'b0);

        //--------------------------------------------------------------
        $display("-- SCSI write: 101 bytes from $2005 --");
        for (i = 0; i < 101; i = i + 1) mem[16'h2005 + i] = i * 3;
        s_rd = 0; s_total = 101; s_taken = 0; s_tc_at = -1; s_stop = 1 << 30;
        setup(0, 24'h002005, 24'd101);
        cyc0 = $time;
        rw(5'h08, 8'h07);                       // TC, write, EN
        wait_done(0, 200000);
        $display("  %0d bytes in %0d ns: %0d KB/s", 101, $time - cyc0, 101 * 1000000 / ($time - cyc0));
        bad = 0;
        for (i = 0; i < 101; i = i + 1) if (s_got[i] !== ((i * 3) & 8'hFF)) bad = bad + 1;
        check("bytes wrong", bad, 0);
        check("bytes sent", s_taken, 101);
        check("TC on the last byte", s_tc_at, 100);
        check("no irq without IE", irq, 1'b0);
        rw(5'h09, 8'h01);

        //--------------------------------------------------------------
        $display("-- SCSI read, the target changes phase after 37 of 64 --");
        s_rd = 1; s_total = 64; s_stop = 37; s_taken = 0; s_tc_at = -1;
        setup(0, 24'h003001, 24'd64);
        rw(5'h08, 8'h05);                       // TC, read, EN
        while (s_taken < 37) @(posedge clk);
        repeat (200) @(posedge clk);
        rr(5'h09, v); check("still BUSY, not DONE", v & 8'h81, 8'h80);
        rw(5'h08, 8'h00);                       // stop
        wait_idle(0);
        rr(5'h09, v); check("stopped: not DONE", v & 8'h01, 8'h00);
        rr(5'h00, v); rr(5'h01, v1); rr(5'h02, v2);
        check("ADDR where it stopped", get24(v, v1, v2), 24'h003001 + 37);
        rr(5'h04, v); rr(5'h05, v1); rr(5'h06, v2);
        check("COUNT left", get24(v, v1, v2), 27);
        bad = 0;
        for (i = 0; i < 37; i = i + 1) if (mem[16'h3001 + i] !== (8'h50 ^ i[7:0])) bad = bad + 1;
        check("bytes wrong", bad, 0);
        check("byte 38 untouched", mem[16'h3001 + 37], 8'hEE);
        check("no TC", s_tc_at, -1);

        //--------------------------------------------------------------
        $display("-- both at once, and a CPU cycle in the middle --");
        BYTE_T = 30;
        f_rd = 1; f_total = 300; f_made = 0; f_taken = 0; f_tc_at = -1; f_overrun = 0;
        s_rd = 1; s_total = 700; s_stop = 1 << 30; s_taken = 0; s_tc_at = -1;
        setup(1, 24'h004000, 24'd300);
        setup(0, 24'h005002, 24'd700);
        rw(5'h18, 8'h05);
        rw(5'h08, 8'h05);
        repeat (2000) @(posedge clk);
        @(posedge clk); c_addr <= 11'h007; c_we <= 0; c_req <= 1;
        @(posedge clk); while (!c_ack) @(posedge clk);
        check("CPU read during DMA", bus_rdata, 8'h37);
        c_req <= 0;
        wait_done(1, 400000);
        wait_done(0, 400000);
        check("FIFO overruns", f_overrun, 0);
        bad = 0;
        for (i = 0; i < 300; i = i + 1) if (mem[16'h4000 + i] !== (8'hA0 ^ i[7:0])) bad = bad + 1;
        check("floppy bytes wrong", bad, 0);
        bad = 0;
        for (i = 0; i < 700; i = i + 1) if (mem[16'h5002 + i] !== (8'h50 ^ i[7:0])) bad = bad + 1;
        check("SCSI bytes wrong", bad, 0);
        check("floppy TC", f_tc_at, 299);
        check("SCSI TC", s_tc_at, 699);
        rw(5'h09, 8'h01); rw(5'h19, 8'h01);

        //--------------------------------------------------------------
        $display("-- a read waits for the cache's store --");
        for (i = 0; i < 16; i = i + 1) mem[16'h6000 + i] = 8'h11;
        f_rd = 0; f_total = 4; f_taken = 0; f_tc_at = -1;
        setup(1, 24'h006000, 24'd4);
        wr_busy = 1;
        rw(5'h18, 8'h07);
        repeat (60) @(posedge clk);
        check("sent during the store", f_taken, 0);
        mem[16'h6000] = 8'h99;                  // the store lands...
        @(negedge clk) wr_busy = 0;             // ...and retires
        wait_done(1, 100000);
        check("the stored byte went out", f_got[0], 8'h99);
        check("bytes sent", f_taken, 4);
        rw(5'h19, 8'h01);

        //--------------------------------------------------------------
        $display("-- COUNT = 0 --");
        f_rd = 0; f_total = 4; f_taken = 0;
        setup(1, 24'h006000, 24'd0);
        rw(5'h18, 8'h03);
        repeat (3) @(posedge clk);
        rr(5'h19, v); check("DONE at once", v & 8'h81, 8'h01);
        check("no cycle", f_taken, 0);

        bl_on = 0;
        $display("  %0d port 2 transactions", port_txns);
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end

    initial begin #20000000; $display("FAIL timeout"); $finish; end
endmodule
`default_nettype wire
