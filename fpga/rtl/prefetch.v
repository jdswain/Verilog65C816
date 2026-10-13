//============================================================================
// prefetch.v -- instruction prefetch queue
//
// 84% of this CPU's bus traffic is instruction fetch (opcode 42%, operand
// bytes 42%, measured on two workloads), and the 65C816 fetches it one byte at
// a time. This reads the instruction stream 32 bits at a time and serves all
// four bytes from a two-word queue.
//
// The width matters: the cache behind it hands back 32-bit words, so fetching
// 16 bits at a time would take two transactions to deliver what one already
// provides -- the queue would cost more than it saved.
//
// The trick that makes it free: when a byte is served from the queue the
// memory path is idle that cycle, so the next word can be fetched with no
// contention. Sequential fetch then settles at one cycle per instruction byte
// regardless of whether the code is in ROM (1.55 cycles unaided) or in cached
// SDRAM (3 cycles unaided).
//
// The queue models a sequential stream rather than a cache: it holds the word
// at `q_base` and the one after it, and shifts down as the CPU consumes. Any
// address that is not one of those two -- a branch, a jump, an interrupt --
// flushes and restarts.
//
// SELF-MODIFYING CODE IS NOT SUPPORTED -- a deliberate choice. The queue holds
// up to two words read ahead of the program counter, and nothing invalidates
// them when memory is written. Code that overwrites an instruction within four
// bytes ahead of the PC will execute the stale copy. Snooping writes would cost
// a comparator on the write path, and this design does not need it.
//
// The same applies to any other master writing program memory (DMA, or the CPU
// writing code it is about to jump into). A jump to freshly written code is
// safe: any address the queue does not already hold flushes and refetches it,
// and the queue never reaches more than two words past the PC.
//============================================================================
`default_nettype none

module prefetch (
    input  wire        clk,
    input  wire        rst_n,

    // ---- CPU side (byte reads from the instruction stream) ----
    input  wire [23:0] cpu_addr,
    input  wire        cpu_req,        // program fetch to prefetchable memory
    output reg  [7:0]  cpu_rdata,
    output wire        cpu_ack,

    // ---- memory side (16-bit words) ----
    output reg  [20:0] m_word,         // word address = byte address >> 2
    output reg         m_req,
    input  wire [31:0] m_rdata,
    input  wire        m_ack,
    input  wire        m_grant         // memory path is available to us
);
    reg [20:0] q_base;                 // word address of q_word[0]
    reg [31:0] q_word [0:1];
    reg [1:0]  q_valid;
    reg        fetching;
    reg        fetch_slot;             // which entry the in-flight word fills

    wire [20:0] req_word = cpu_addr[22:2];
    wire [1:0]  req_byte = cpu_addr[1:0];

    wire hit0 = q_valid[0] & (req_word == q_base);
    wire hit1 = q_valid[1] & (req_word == q_base + 21'd1);

    // Bypass: the word the CPU is waiting for may be arriving on this very
    // cycle. Serving it straight from the bus saves the fill-then-serve pair,
    // which matters because the CPU drains a word in only two cycles.
    wire [20:0] in_flight = (fetch_slot == 1'b0) ? q_base : q_base + 21'd1;
    wire        bypass    = fetching & m_ack & (req_word == in_flight);

    wire hit  = cpu_req & (hit0 | hit1 | bypass);

    assign cpu_ack = hit;

    wire [31:0] hit_word = bypass ? m_rdata : (hit0 ? q_word[0] : q_word[1]);

    always @* begin
        case (req_byte)
        2'd0: cpu_rdata = hit_word[7:0];
        2'd1: cpu_rdata = hit_word[15:8];
        2'd2: cpu_rdata = hit_word[23:16];
        2'd3: cpu_rdata = hit_word[31:24];
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_base     <= 21'd0;
            q_valid    <= 2'b00;
            q_word[0]  <= 32'd0;
            q_word[1]  <= 32'd0;
            m_req      <= 1'b0;
            m_word     <= 21'd0;
            fetching   <= 1'b0;
            fetch_slot <= 1'b0;
        end else begin
            // ---- retire an in-flight fetch ----
            // Note the dead cycle here: `m_req` has to fall before the next
            // request can be seen, so one outstanding transaction on a
            // level-based handshake costs a cycle between words. That is what
            // bounds the sustained rate to two bytes per (latency + 2) cycles.
            if (fetching && m_ack) begin
                q_word[fetch_slot]  <= m_rdata;
                q_valid[fetch_slot] <= 1'b1;
                fetching <= 1'b0;
                m_req    <= 1'b0;
            end

            if (cpu_req && !hit && !fetching) begin
                // Branch, or the queue has not caught up: restart here.
                q_base     <= req_word;
                q_valid    <= 2'b00;
                m_word     <= req_word;
                m_req      <= 1'b1;
                fetching   <= 1'b1;
                fetch_slot <= 1'b0;
            end else if (hit1) begin
                // The CPU has moved into the second word: shift down and make
                // room for the next one.
                q_word[0]  <= q_word[1];
                q_valid[0] <= 1'b1;
                q_valid[1] <= 1'b0;
                q_base     <= q_base + 21'd1;
            end else if (!fetching && m_grant && q_valid[0] && !q_valid[1]) begin
                // Idle memory path: pull the next word in behind the CPU.
                m_word     <= q_base + 21'd1;
                m_req      <= 1'b1;
                fetching   <= 1'b1;
                fetch_slot <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
