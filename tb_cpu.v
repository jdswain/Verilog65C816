//============================================================================
// tb_cpu.v -- self-checking testbench for cpu_65c816
//
// 128 KB of RAM (banks $00 and $01), loaded from test.hex.
// The test program reports its result by writing to $00F000:
//   data 0    -> PASS
//   data != 0 -> FAIL, data = failing test number
// A write to $00F001 prints the byte as a character (debug console).
// A write to $00F002 drives the IRQ line (1 = assert irq_n low).
// A write to $00F003 pulses NMI low for a few cycles.
//============================================================================
`timescale 1ns/1ps

module tb_cpu;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [23:0] addr;
    wire [7:0]  wdata;
    wire        we, vld;
    wire        stopped;
    wire        vpa, vda, vpb_n, mlb_n;

    reg [7:0] mem [0:131071];          // banks $00-$01
    wire [7:0] rdata = mem[addr[16:0]];

    reg irq_line = 1'b1;
    reg nmi_line = 1'b1;
    reg abort_line = 1'b1;
    reg [3:0] nmi_cnt = 4'd0;

    cpu_65c816 dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .addr    (addr),
        .wdata   (wdata),
        .rdata   (rdata),
        .we      (we),
        .vld     (vld),
        .rdy     (1'b1),
        .irq_n   (irq_line),
        .nmi_n   (nmi_line),
        .abort_n (abort_line),
        .vpa     (vpa),
        .vda     (vda),
        .vpb_n   (vpb_n),
        .mlb_n   (mlb_n),
        .e_flag  (),
        .m_flag  (),
        .x_flag  (),
        .stopped (stopped)
    );

    // Status-pin invariants (checked every cycle). These catch a bad
    // VPA/VDA/VPB/MLB classification without re-deriving it from FSM state.
    reg saw_vpb = 1'b0, saw_mlb = 1'b0;
    always @(posedge clk) if (rst_n) begin
        if (vld && !(vpa || vda))
            $display("VPA/VDA FAIL: active cycle (vld) with no valid address @%06x", addr);
        if (we && !(vda && !vpa))
            $display("VPA/VDA FAIL: write not classified as data @%06x", addr);
        if (!vpb_n && !vda)
            $display("VPB FAIL: vector pull without valid data address @%06x", addr);
        if (!mlb_n && !vda)
            $display("MLB FAIL: memory lock without valid data address @%06x", addr);
        if (!vpb_n) saw_vpb <= 1'b1;
        if (!mlb_n) saw_mlb <= 1'b1;
    end

    integer cycles = 0;
    always @(posedge clk) cycles = cycles + 1;

    // interrupt lines driven by magic-port writes.
    // A write to $00F004 "arms" a mid-block-move IRQ: the testbench then
    // asserts irq_n low once the move's 2nd byte is written (state S_MVW),
    // so the IRQ lands partway through an in-progress MVN/MVP.
    // A write to $00F005 "arms" an ABORT: abort_n is then pulsed low across
    // the *next* instruction (asserted at its opcode fetch, released a few
    // cycles later so the abort handler itself is not aborted).
    localparam ST_MVW   = 5'd18;
    localparam ST_FETCH = 5'd0;
    reg arm_mvirq = 1'b0;
    integer mvw_seen = 0;
    reg arm_abort = 1'b0;
    integer abort_cnt = 0;
    always @(posedge clk) begin
        if (rst_n && vld && we && addr == 24'h00F002)
            irq_line <= (wdata == 8'h00);
        if (rst_n && vld && we && addr == 24'h00F004) begin
            arm_mvirq <= 1'b1; mvw_seen <= 0;
        end else if (arm_mvirq && vld && we && dut.state == ST_MVW) begin
            mvw_seen <= mvw_seen + 1;
            if (mvw_seen == 1) begin irq_line <= 1'b0; arm_mvirq <= 1'b0; end
        end
        if (rst_n && vld && we && addr == 24'h00F003) begin
            nmi_line <= 1'b0;
            nmi_cnt  <= 4'd4;
        end else if (nmi_cnt > 0) begin
            nmi_cnt <= nmi_cnt - 4'd1;
            if (nmi_cnt == 4'd1) nmi_line <= 1'b1;
        end
        // abort arming / pulse
        if (rst_n && vld && we && addr == 24'h00F005)
            arm_abort <= 1'b1;
        else if (arm_abort && dut.state == ST_FETCH) begin
            abort_line <= 1'b0; abort_cnt <= 4; arm_abort <= 1'b0;
        end else if (abort_cnt > 0) begin
            abort_cnt <= abort_cnt - 1;
            if (abort_cnt == 1) abort_line <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && vld && we) begin
            mem[addr[16:0]] <= wdata;
            if (addr == 24'h00F000) begin
                if (wdata != 8'h00)
                    $display("FAIL: test %0d  (%0d cycles)", wdata, cycles);
                else if (!saw_vpb)
                    $display("FAIL: VPB (vector pull) never asserted");
                else if (!saw_mlb)
                    $display("FAIL: MLB (memory lock) never asserted");
                else
                    $display("PASS  (%0d cycles)", cycles);
                #20 $finish;
            end
            if (addr == 24'h00F001)
                $write("%c", wdata);
        end
    end

    // the memory image: test.hex, or +hex=file (make banked)
    // (zeroed first: an image shorter than the memory leaves no x behind)
    reg [8*256-1:0] hexfile;
    integer k;
    initial begin
        for (k = 0; k < 131072; k = k + 1) mem[k] = 8'h00;
        if (!$value$plusargs("hex=%s", hexfile)) hexfile = "test.hex";
        $readmemh(hexfile, mem);
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT: no result written (PC stuck?)");
        $finish;
    end

    // bus trace: vvp sim +trace=N  (print the first N bus cycles)
    integer trace_n = 0;
    integer dummy;
    initial dummy = $value$plusargs("trace=%d", trace_n);
    always @(posedge clk) begin
        if (rst_n && trace_n > 0) begin
            trace_n = trace_n - 1;
            if (vld)
                $display("%s %06x %s %02x %s%s%s%s st=%0d ir=%02x pc=%04x a=%04x x=%04x y=%04x s=%04x p=%b%b..%b%b%b%b e=%b",
                         we ? "W" : "R", addr, we ? "<-" : "->",
                         we ? wdata : rdata,
                         vpa ? "P" : "-", vda ? "D" : "-",
                         vpb_n ? "-" : "V", mlb_n ? "-" : "M",
                         dut.state, dut.IR, dut.PC,
                         dut.A, dut.X, dut.Y, dut.S,
                         dut.fN, dut.fV, dut.fD, dut.fI, dut.fZ, dut.fC, dut.fE);
            else
                $display(". ------  %s%s%s%s st=%0d",
                         vpa ? "P" : "-", vda ? "D" : "-",
                         vpb_n ? "-" : "V", mlb_n ? "-" : "M", dut.state);
        end
    end

endmodule
