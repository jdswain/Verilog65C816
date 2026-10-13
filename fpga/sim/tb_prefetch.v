//============================================================================
// tb_prefetch.v -- drive the prefetch queue against a stub memory.
//
// Checks the bytes are right, that a branch to an unheld address refetches,
// and -- the point of the whole exercise -- that sequential fetch settles at
// one cycle per byte once the queue is primed.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_prefetch;
    // Memory latency in cycles from request to ack. The boot ROM is a
    // registered block RAM read (1); a cache hit is nearer 3.
    parameter integer LAT = 1;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;

    reg  [23:0] cpu_addr = 0;
    reg         cpu_req = 0;
    wire [7:0]  cpu_rdata;
    wire        cpu_ack;

    wire [20:0] m_word;
    wire        m_req;
    reg  [31:0] m_rdata = 0;
    reg         m_ack = 0;

    prefetch dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_addr(cpu_addr), .cpu_req(cpu_req),
        .cpu_rdata(cpu_rdata), .cpu_ack(cpu_ack),
        .m_word(m_word), .m_req(m_req), .m_rdata(m_rdata),
        .m_ack(m_ack), .m_grant(1'b1)
    );

    // Word w holds bytes 4w..4w+3; each byte equals its own address (low 8
    // bits) so any served byte is self-checking.
    function [7:0] byte_at(input [20:0] w, input [1:0] sel);
        byte_at = {w[5:0], sel};
    endfunction

    // Stub memory: word w contains bytes (2w) and (2w+1), each byte = its
    // own address, so any served byte is self-checking. Two cycles latency.
    reg [1:0] lat = 0;
    reg [20:0] pend;
    // Start on the rising edge of m_req: the requester holds it high for one
    // more cycle after ack, and a level-triggered stub would restart the
    // transaction with a stale address.
    reg m_req_d = 0;
    always @(posedge clk) m_req_d <= m_req;
    always @(posedge clk) begin
        m_ack <= 1'b0;
        if (m_req && !m_req_d && lat == 0) begin
            lat <= LAT[1:0]; pend <= m_word;
        end else if (lat > 1) begin
            lat <= lat - 1;
        end else if (lat == 1) begin
            // byte 2w+1 in the high half, byte 2w in the low half
            m_rdata <= {byte_at(pend, 2'd3), byte_at(pend, 2'd2),
                        byte_at(pend, 2'd1), byte_at(pend, 2'd0)};
            m_ack   <= 1'b1;
            lat     <= 0;
        end
    end

    integer errors = 0, i, cyc = 0, t0, tseq;
    always @(posedge clk) cyc = cyc + 1;

    reg [7:0] got;
    task fetch(input [23:0] a);
        begin
            @(negedge clk); cpu_addr = a; cpu_req = 1;
            while (!cpu_ack) @(negedge clk);
            got = cpu_rdata;
            @(negedge clk); cpu_req = 0;
            if (got !== a[7:0]) begin
                if (errors < 6)
                    $display("FAIL addr %06x: got %02x want %02x", a, got, a[7:0]);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;

        // ---- sequential run from a cold queue ----
        for (i = 0; i < 32; i = i + 1) fetch(i[23:0]);
        $display("sequential:  %0d error(s)", errors);

        // ---- branch to an address the queue does not hold ----
        fetch(24'h001000);
        fetch(24'h001001);
        fetch(24'h001002);
        $display("after branch: %0d error(s)", errors);

        // ---- steady-state cost ----
        // Drive it the way the CPU bus does: hold the request and present the
        // next address the moment ack appears, one clock per iteration. The
        // earlier `fetch` task burns two edges per byte and would measure
        // itself rather than the queue.
        fetch(24'h002000);
        @(negedge clk); cpu_req = 1;
        i = 0; t0 = cyc;
        while (i < 32) begin
            cpu_addr = 24'h002001 + i[23:0];
            #1;
            if (cpu_ack) i = i + 1;
            @(posedge clk);
            @(negedge clk);
        end
        tseq = cyc - t0;
        cpu_req = 0;
        $display("LAT=%0d: 32 sequential bytes took %0d cycles (%.2f per byte)",
                 LAT, tseq, tseq/32.0);
        // Two bytes arrive per memory access, so the floor is (LAT+1)/2 cycles
        // per byte; anything close to that means the queue is keeping up.
        if (tseq > 32 * (LAT + 2)) begin
            $display("FAIL: worse than the memory can explain");
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end

    initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
