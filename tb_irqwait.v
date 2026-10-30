//============================================================================
// tb_irqwait.v -- interrupts taken while the bus waits (make irqwait)
//
// cpu_65c816 runs irqwait.s from 256 KB of RAM (banks $00-$03) behind a bus
// that behaves like the SoC's cache: an access starts when `vld` is seen,
// waits 1 to 4 cycles, and is then completed and acknowledged (`rdy`) even
// if the core has meanwhile dropped `vld` -- the cache cannot abandon a
// line fill. The core must therefore hold an access steady until `rdy`;
// the bench checks that, and raises the IRQ every 40 to 295 cycles.
//
//   +nowait  every access in one cycle (rdy high), the reference
//   +noirq   no interrupts
// It prints the program's checksum and tick count; make irqwait compares
// the checksum of a run with waits and IRQs with the reference's.
//============================================================================
`timescale 1ns/1ps

module tb_irqwait;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [23:0] addr;
    wire [7:0]  wdata;
    wire        we, vld, stopped;

    reg [7:0] mem [0:262143];

    reg nowait = 1'b0, noirq = 1'b0;
    initial begin
        nowait = $test$plusargs("nowait");
        noirq  = $test$plusargs("noirq");
    end

    // the bus: an access latched when it starts, finished after its wait
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    reg        busy = 1'b0;
    reg [1:0]  cnt;
    reg [23:0] la;
    reg        lwe;
    reg [7:0]  lwd;
    wire       rdy   = nowait ? 1'b1 : busy & (cnt == 2'd0);
    wire [23:0] ra   = nowait ? addr : la;
    wire [7:0] rdata = mem[ra[17:0]];
    wire [17:0] wa = {ra[17:2], 2'b00};
    wire [31:0] rdata32 = {mem[wa | 18'd3], mem[wa | 18'd2], mem[wa | 18'd1], mem[wa]};

    wire       done  = nowait ? (vld & rst_n) : (busy & (cnt == 2'd0));
    wire [23:0] da   = nowait ? addr : la;
    wire       dwe   = nowait ? we : lwe;
    wire [7:0] dwd   = nowait ? wdata : lwd;

    always @(posedge clk) if (rst_n && !nowait) begin
        if (busy) begin
            if (cnt == 2'd0) busy <= 1'b0;
            else cnt <= cnt - 2'd1;
        end else if (vld) begin
            busy <= 1'b1; la <= addr; lwe <= we; lwd <= wdata;
            cnt <= lfsr[1:0];
        end
    end

    // the contract: an access waiting (vld, no rdy) is the same next cycle
    reg        p_wait = 1'b0;
    reg [23:0] p_addr;
    reg        p_we;
    reg [7:0]  p_wd;
    integer    violations = 0;
    always @(posedge clk) if (rst_n) begin
        if (p_wait && (!vld || addr != p_addr || we != p_we || (we && wdata != p_wd))) begin
            if (violations < 5)
                $display("CONTRACT: waiting access %s %06x changed to %s %06x (vld %b) st=%0d @%0t",
                         p_we ? "W" : "R", p_addr, we ? "W" : "R", addr, vld, dut.state, $time);
            violations = violations + 1;
        end
        p_wait <= vld & ~rdy; p_addr <= addr; p_we <= we; p_wd <= wdata;
    end

    // the IRQ, and the ports
    reg irq_line = 1'b1;
    integer gap = 100, gapmin = 40;
    initial if (!$value$plusargs("gap=%d", gapmin)) gapmin = 40;
    reg [15:0] r_sum, r_ticks;
    integer cycles = 0;
    always @(posedge clk) if (rst_n) begin
        cycles = cycles + 1;
        if (!noirq && irq_line) begin
            if (gap == 0) begin irq_line <= 1'b0; gap = gapmin + lfsr[15:8]; end
            else gap = gap - 1;
        end
        if (done && dwe) begin
            mem[da[17:0]] <= dwd;
            case (da)
            24'h00F002: irq_line <= 1'b1;
            24'h00F010: r_sum[7:0]    <= dwd;
            24'h00F011: r_sum[15:8]   <= dwd;
            24'h00F012: r_ticks[7:0]  <= dwd;
            24'h00F013: r_ticks[15:8] <= dwd;
            24'h00F000: begin
                if (dwd != 8'h00) $display("FAIL: error %0d  (%0d cycles)", dwd, cycles);
                else $display("DONE sum=%02x%02x ticks=%02x%02x [21011]=%02x [34D00]=%02x%02x cycles=%0d violations=%0d", mem[18'hF011], mem[18'hF010], mem[18'hF013], mem[18'hF012], mem[18'h21011], mem[18'h34D01], mem[18'h34D00],
                              cycles, violations);
                #20 $finish;
            end
            default: ;
            endcase
        end
    end

    cpu_65c816 dut (
        .clk(clk), .rst_n(rst_n),
        .addr(addr), .wdata(wdata), .rdata(rdata), .rdata32(rdata32), .r32(1'b1), .we(we), .vld(vld),
        .rdy(rdy), .irq_n(irq_line), .nmi_n(1'b1), .abort_n(1'b1),
        .vpa(), .vda(), .vpb_n(), .mlb_n(),
        .e_flag(), .m_flag(), .x_flag(), .stopped(stopped)
    );

    reg [8*256-1:0] hexfile;
    integer k;
    initial begin
        for (k = 0; k < 262144; k = k + 1) mem[k] = 8'h00;
        if (!$value$plusargs("hex=%s", hexfile)) hexfile = "irqwait.mem";
        $readmemh(hexfile, mem);
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
    end

    initial begin
        #100_000_000;
        $display("TIMEOUT: PC=%02x:%04x st=%0d vld=%b rdy=%b busy=%b S=%04x D=%04x ticks=%02x%02x count=%02x%02x cycles=%0d violations=%0d", dut.PBR, dut.PC, dut.state, vld, rdy, busy, dut.S, dut.D, mem[18'hFE05], mem[18'hFE04], mem[18'h34D03], mem[18'h34D02], cycles, violations);
        $finish;
    end

endmodule
