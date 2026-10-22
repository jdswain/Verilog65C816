//============================================================================
// cache.v -- unified write-through cache between the CPU and SDRAM
//
// Direct-mapped, 256 lines x 16 bytes = 4 KB, backed by block RAM. A line is
// exactly one SDRAM read burst, so a miss costs one burst and nothing is
// wasted.
//
// THE READ PATH IS 32 BITS WIDE. The storage always was -- four byte-wide
// arrays read in parallel -- but the interface used to hand back one byte and
// discard the other three, so every byte of an instruction cost a full lookup
// (3 cycles). The last word read is now held, and any further byte inside it is
// answered combinationally in a single cycle. Sequential fetch therefore costs
// 3 cycles for the first byte of a word and 1 for the next three: 1.5 cycles
// per byte instead of 3.
//
// `rdata32` exposes the whole word, which is what a future 16-bit CPU data bus
// would take.
//
// WRITE-THROUGH, not write-back. The display scans the framebuffer out of
// SDRAM continuously and asynchronously, so there is no safe moment to flush
// dirty lines -- "flush before the next scan" would mean every frame. Writing
// through keeps SDRAM authoritative at all times, which is what makes the
// video read path correct without any coherency machinery.
//
// Writes do not allocate. A write that misses updates SDRAM only, leaving the
// cache untouched; allocating would cost a line fill to satisfy a write whose
// data we already have.
//
// Stores are POSTED: the write is handed to SDRAM and the CPU is released in
// the same cycle, without waiting for it to retire. Read hits are served out of
// the cache array while that write is still in flight, which is the whole point
// -- an earlier version drained the write only when the CPU was idle, and since
// the CPU is essentially never idle, every store stalled behind the previous
// one and the cache was barely faster than no cache at all.
//
// Ordering is kept by making anything that needs the SDRAM port -- a line fill
// or another store -- wait for the in-flight write to retire first. A read that
// hits needs no port, so it never waits.
//
// INVALIDATION. The CPU is not the only writer: the blitter (and later DMA)
// writes SDRAM through the controller's memory-master port, behind the cache's
// back. Each such write is reported here once it has retired, and if the line
// holding that word is cached it is dropped, to be refilled on its next use.
//
// Dropping the tag is not enough by itself, because a lookup already in
// progress may have read the tag while it was still valid and be about to
// latch the old data as the held word -- which is answered without consulting
// the tag again. So an invalidation that lands on the access in progress
// also "poisons" it: the access completes, but leaves no held word behind.
// New lookups wait the few cycles an invalidation takes, and the held word is
// dropped the moment the report arrives, so a read that starts after a
// master's write has finished always sees what was written.
//
// A report is only made after the master's write has retired, so it can never
// arrive ahead of a line fill that read the old data: SDRAM transactions are
// serialized, and such a fill has finished before the write began.
//============================================================================
`default_nettype none

module cache #(
    parameter integer LINE_BYTES = 16,
    parameter integer LINES      = 256
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- CPU side (byte accesses) ----
    input  wire [22:0] addr,
    input  wire [7:0]  wdata,
    output wire [7:0]  rdata,
    output wire [31:0] rdata32,      // the whole held word
    input  wire        req,          // held high for the access
    input  wire        we,
    output wire        ack,          // one cycle; rdata valid here

    // ---- SDRAM side (port 1 of sdram_burst) ----
    output reg         m_req,
    output reg         m_we,
    output reg  [20:0] m_addr,
    output reg  [31:0] m_wdata,
    output reg  [3:0]  m_wmask,
    input  wire        m_done,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,

    // ---- invalidation: a word some other master has just written ----
    // One-cycle pulse. Reports must be at least four cycles apart, which the
    // SDRAM controller guarantees: a write transaction takes longer than that.
    input  wire        inv_valid,
    input  wire [20:0] inv_addr,     // word address, as on the SDRAM port

    // ---- a posted store is on its way to SDRAM ----
    // From the cycle the CPU is released until the write retires. Another
    // master that reads what the CPU has just written waits for this: port 2
    // outranks the CPU's port and could otherwise read the old word.
    output wire        wr_busy,

    // ---- statistics, for measuring what the cache actually buys ----
    output reg  [31:0] stat_hits,
    output reg  [31:0] stat_misses
);
    localparam integer OFF_BITS = 4;                 // 16 bytes per line
    localparam integer IDX_BITS = 8;                 // 256 lines
    localparam integer TAG_BITS = 23 - OFF_BITS - IDX_BITS;   // 11

    // Address split: [ tag | index | word | byte ]
    wire [TAG_BITS-1:0] a_tag  = addr[22:OFF_BITS+IDX_BITS];
    wire [IDX_BITS-1:0] a_idx  = addr[OFF_BITS+IDX_BITS-1:OFF_BITS];
    wire [1:0]          a_word = addr[3:2];
    wire [1:0]          a_byte = addr[1:0];

    // Tag store: {valid, tag}
    reg [TAG_BITS:0] tags [0:LINES-1];

    // Data store, split into four byte-wide arrays rather than one 32-bit
    // array. A cache must write a single byte lane, and block RAM has no
    // partial-word write: expressed as `data[n][7:0] <= x` the tools cannot
    // infer BSRAM at all and spend minutes trying. One array per lane makes
    // every write a whole-element write, which infers cleanly.
    reg [7:0] data0 [0:LINES*4-1];
    reg [7:0] data1 [0:LINES*4-1];
    reg [7:0] data2 [0:LINES*4-1];
    reg [7:0] data3 [0:LINES*4-1];

    integer i;
    initial begin
        for (i = 0; i < LINES; i = i + 1) tags[i] = {1'b0, {TAG_BITS{1'b0}}};
    end

    // Held word: the last 32 bits read, and which word it was.
    reg [31:0]          hold_data;
    reg [TAG_BITS-1:0]  hold_tag;
    reg [IDX_BITS-1:0]  hold_idx;
    reg [1:0]           hold_word;
    reg                 hold_valid;

    // Written as an XOR then a NOR-reduce rather than three `==` compares.
    // Equality via `==` was being mapped onto the carry chain -- seven ripple
    // stages for 21 bits -- and this comparator is on the critical path, since
    // it gates the combinational `ack` that feeds the CPU's ALU. XOR-reduce
    // gives a LUT tree of about three levels instead.
    wire [20:0] hold_diff = {a_tag, a_idx, a_word} ^ {hold_tag, hold_idx, hold_word};
    wire hold_match = hold_valid & ~(|hold_diff);
    wire fast = req & ~we & hold_match;

    reg  [7:0] rdata_r;
    reg        ack_r;

    // `ack` is combinational on a held-word hit, so the byte costs a single
    // cycle. That puts the tag+index+word compare in front of the CPU's
    // ready input -- but, since the change described below, no longer in front
    // of its read data and ALU.
    assign ack     = ack_r | fast;
    assign rdata32 = hold_data;

    // The data is selected by `ack_r`, a register, and NOT by `fast`. Selected
    // by `fast`, the 21-bit held-word compare sat in front of the read data and
    // so in front of the CPU's ALU and flags: address -> compare -> data mux ->
    // adder -> flags was the design's critical path, at 3% margin. The compare
    // only needs to decide WHETHER the CPU takes the data (`ack`), which is a
    // late-arriving enable; it does not need to decide WHICH data.
    //
    // This is equivalent. When `ack_r` is low the only way the CPU can be
    // taking data is the fast path, so the held byte is right, and if it is
    // not a fast hit either then `ack` is low and the CPU ignores `rdata`.
    // When `ack_r` is high the access finishing is the slow path's, and
    // `rdata_r` is its answer -- even if the word it just loaded into the
    // hold register makes `fast` true in the same cycle.
    assign rdata   = ack_r ? rdata_r : pick(hold_data, a_byte);

    reg [TAG_BITS:0] tag_q;
    reg [31:0]       data_q;
    reg [IDX_BITS-1:0] idx_r;
    reg [TAG_BITS-1:0] tag_r;
    reg [1:0]        word_r, byte_r;
    reg              we_r;
    reg [7:0]        wdata_r;

    wire hit = tag_q[TAG_BITS] & (tag_q[TAG_BITS-1:0] == tag_r);

    // write-through buffer (one entry)
    reg        wb_full;
    reg [20:0] wb_addr;
    reg [31:0] wb_data;
    reg [3:0]  wb_mask;

    localparam [3:0] S_IDLE  = 4'd0, S_CHECK = 4'd1, S_WAIT  = 4'd2,
                     S_FILL  = 4'd3, S_FILL_DONE = 4'd4, S_SERVE = 4'd5,
                     S_GAP   = 4'd6;
    reg [3:0] state;
    reg [1:0] fill_word;

    // The tag store has one write port, driven from these so that a line fill
    // and an invalidation -- two different places in the logic below -- do not
    // each describe a write of their own. Described separately, the tools see
    // two write ports and give up on inferring a RAM.
    reg                 tag_we;
    reg [IDX_BITS-1:0]  tag_waddr;
    reg [TAG_BITS:0]    tag_wdata;
    always @(posedge clk) if (tag_we) tags[tag_waddr] <= tag_wdata;

    // Invalidation: look the line's tag up (a second read port on the tag
    // store), then clear it if it matches.
    reg                 inv_pend, inv_rd, poison;
    reg [20:0]          inv_a;
    reg [TAG_BITS:0]    inv_tag_q;
    wire [TAG_BITS-1:0] inv_tag = inv_a[20:IDX_BITS+2];
    wire [IDX_BITS-1:0] inv_idx = inv_a[IDX_BITS+1:2];
    wire inv_line_hit = inv_tag_q[TAG_BITS] & (inv_tag_q[TAG_BITS-1:0] == inv_tag);

    // The access in progress, or the one being accepted this cycle.
    wire [IDX_BITS-1:0] cur_idx = (state == S_IDLE) ? a_idx : idx_r;
    wire [TAG_BITS-1:0] cur_tag = (state == S_IDLE) ? a_tag : tag_r;
    wire                cur_any = (state != S_IDLE) | req;

    // The step that acts on an invalidation. It waits a cycle if a fill is
    // claiming the tag write port, and looks the tag up again when it does.
    wire fill_ending = (state == S_FILL) & m_done;
    wire inv_act     = inv_pend & inv_rd & ~inv_valid & ~fill_ending;
    wire inv_cur     = inv_act & cur_any & (cur_idx == inv_idx) & (cur_tag == inv_tag);
    reg       m_busy;             // an SDRAM transaction is in flight
    assign wr_busy = m_busy & m_we;

    // byte lane helpers
    function [7:0] pick(input [31:0] w, input [1:0] b);
        case (b)
        2'd0: pick = w[7:0];
        2'd1: pick = w[15:8];
        2'd2: pick = w[23:16];
        2'd3: pick = w[31:24];
        endcase
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            ack_r       <= 1'b0;
            hold_valid  <= 1'b0;
            m_req       <= 1'b0;
            m_we        <= 1'b0;
            m_busy      <= 1'b0;
            fill_word   <= 2'd0;
            stat_hits   <= 32'd0;
            stat_misses <= 32'd0;
            rdata_r     <= 8'd0;
            tag_we      <= 1'b0;
            inv_pend    <= 1'b0;
            inv_rd      <= 1'b0;
            poison      <= 1'b0;
        end else begin
            ack_r  <= 1'b0;
            tag_we <= 1'b0;

            // Retire whatever is in flight. A fill needs its data first, so it
            // clears m_busy from S_FILL instead.
            if (m_busy && m_done && m_we) begin
                m_req  <= 1'b0;
                m_we   <= 1'b0;
                m_busy <= 1'b0;
            end

            case (state)
            //--------------------------------------------------------
            S_IDLE: begin
                // No new lookup while an invalidation is being worked out, or
                // while a tag write is still on its way to the store: either
                // could let the lookup read a tag that is about to be dropped.
                if (req && !fast && !inv_pend && !tag_we) begin
                    tag_q   <= tags[a_idx];
                    data_q  <= {data3[{a_idx, a_word}], data2[{a_idx, a_word}],
                                data1[{a_idx, a_word}], data0[{a_idx, a_word}]};
                    idx_r   <= a_idx;
                    tag_r   <= a_tag;
                    word_r  <= a_word;
                    byte_r  <= a_byte;
                    we_r    <= we;
                    wdata_r <= wdata;
                    state   <= S_CHECK;
                    poison  <= 1'b0;           // a new access starts clean
                end
            end

            //--------------------------------------------------------
            S_CHECK: begin
                if (hit) stat_hits   <= stat_hits + 1'b1;
                else     stat_misses <= stat_misses + 1'b1;

                if (we_r) begin
                    // Write-through, no allocate: refresh the line if it is
                    // present, and push the store at SDRAM regardless.
                    if (hit) begin
                        case (byte_r)
                        2'd0: data0[{idx_r, word_r}] <= wdata_r;
                        2'd1: data1[{idx_r, word_r}] <= wdata_r;
                        2'd2: data2[{idx_r, word_r}] <= wdata_r;
                        2'd3: data3[{idx_r, word_r}] <= wdata_r;
                        endcase
                        // the held copy would now be stale
                        if (hold_valid && idx_r == hold_idx &&
                            word_r == hold_word && tag_r == hold_tag)
                            hold_valid <= 1'b0;
                    end
                    if (!m_busy) begin
                        m_addr  <= {tag_r, idx_r, word_r};
                        m_wdata <= {4{wdata_r}};
                        m_wmask <= (4'b0001 << byte_r);
                        m_we    <= 1'b1;
                        m_req   <= 1'b1;
                        m_busy  <= 1'b1;
                        ack_r   <= 1'b1;          // posted: CPU carries on
                        state   <= S_GAP;
                    end else begin
                        state <= S_WAIT;          // port busy; retry when free
                    end
                end else if (hit) begin
                    // Served from the array: needs no SDRAM port, so this is
                    // unaffected by any write still in flight.
                    rdata_r <= pick(data_q, byte_r);
                    ack_r   <= 1'b1;
                    state   <= S_GAP;
                    hold_data  <= data_q;      // keep the other three bytes
                    hold_tag   <= tag_r;
                    hold_idx   <= idx_r;
                    hold_word  <= word_r;
                    hold_valid <= 1'b1;
                end else begin
                    state <= S_WAIT;
                end
            end

            //--------------------------------------------------------
            // Wait for the port, then do whatever S_CHECK could not.
            S_WAIT: begin
                if (!m_busy) begin
                    if (we_r) begin
                        m_addr  <= {tag_r, idx_r, word_r};
                        m_wdata <= {4{wdata_r}};
                        m_wmask <= (4'b0001 << byte_r);
                        m_we    <= 1'b1;
                        m_req   <= 1'b1;
                        m_busy  <= 1'b1;
                        ack_r   <= 1'b1;
                        state   <= S_GAP;
                    end else begin
                        m_addr    <= {tag_r, idx_r, 2'b00};
                        m_we      <= 1'b0;
                        m_req     <= 1'b1;
                        m_busy    <= 1'b1;
                        fill_word <= 2'd0;
                        state     <= S_FILL;
                    end
                end
            end

            //--------------------------------------------------------
            S_FILL: begin
                if (m_rvalid) begin
                    data0[{idx_r, fill_word}] <= m_rdata[7:0];
                    data1[{idx_r, fill_word}] <= m_rdata[15:8];
                    data2[{idx_r, fill_word}] <= m_rdata[23:16];
                    data3[{idx_r, fill_word}] <= m_rdata[31:24];
                    fill_word <= fill_word + 1'b1;
                end
                if (m_done) begin
                    m_req       <= 1'b0;
                    m_busy      <= 1'b0;
                    tag_we      <= 1'b1;
                    tag_waddr   <= idx_r;
                    tag_wdata   <= {1'b1, tag_r};
                    state       <= S_FILL_DONE;
                    // this line's contents changed underneath the held word
                    if (hold_valid && idx_r == hold_idx) hold_valid <= 1'b0;
                end
            end

            // One cycle for the data store to present the wanted word.
            S_FILL_DONE: begin
                data_q <= {data3[{idx_r, word_r}], data2[{idx_r, word_r}],
                           data1[{idx_r, word_r}], data0[{idx_r, word_r}]};
                state  <= S_SERVE;
            end

            S_SERVE: begin
                rdata_r <= pick(data_q, byte_r);
                ack_r   <= 1'b1;
                state   <= S_GAP;
                hold_data  <= data_q;
                hold_tag   <= tag_r;
                hold_idx   <= idx_r;
                hold_word  <= word_r;
                hold_valid <= 1'b1;
            end

            // One cycle for the requester to see ack and move on, so we do not
            // re-latch the finished access's address as a fresh request.
            S_GAP: state <= S_IDLE;

            default: state <= S_IDLE;
            endcase

            //--------------------------------------------------------
            // Invalidation. This comes after the case statement so that its
            // assignments to hold_valid and poison take precedence over the
            // state machine's in the same cycle.
            //--------------------------------------------------------
            if (inv_valid) begin
                inv_a    <= inv_addr;
                inv_pend <= 1'b1;
                inv_rd   <= 1'b0;
                // The held word is answered without a lookup, so it cannot
                // wait for the tag to be checked: drop it at once.
                if (hold_idx == inv_addr[IDX_BITS+1:2] &&
                    hold_tag == inv_addr[20:IDX_BITS+2])
                    hold_valid <= 1'b0;
            end else if (inv_pend && !inv_rd) begin
                inv_tag_q <= tags[inv_idx];
                inv_rd    <= 1'b1;
            end else if (inv_pend && fill_ending) begin
                inv_rd <= 1'b0;                // that fill may be this line
            end else if (inv_act) begin
                if (inv_line_hit) begin
                    tag_we    <= 1'b1;
                    tag_waddr <= inv_idx;
                    tag_wdata <= {1'b0, {TAG_BITS{1'b0}}};
                end
                if (hold_idx == inv_idx && hold_tag == inv_tag)
                    hold_valid <= 1'b0;
                if (inv_cur) poison <= 1'b1;
                inv_pend <= 1'b0;
            end

            // A poisoned access may finish, but must not leave a held word.
            if ((poison | inv_cur) && (state == S_CHECK || state == S_SERVE))
                hold_valid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
