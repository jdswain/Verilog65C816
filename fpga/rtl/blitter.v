//============================================================================
// blitter.v -- rectangle blitter for the 4-bit-per-pixel display
//
// Copies or fills a rectangle of pixels, combining source with destination
// through one of 16 logic operations, optionally skipping source pixels of one
// colour. It is a master on the SDRAM controller's memory-master port, so it
// runs alongside the CPU rather than through it.
//
// The register model follows the Atari ST's BLiTTER -- source and destination
// with a stride each, a width and height, the same 16 logic operations with
// the same numbering -- but the datapath does not, because this display is not
// planar:
//
//  * ADDRESSES ARE IN PIXELS. A pixel is a nibble, so a pixel address is a
//    byte address times two, plus one for the right-hand pixel of the byte.
//    8 MB is 2^24 nibbles, so a pixel address is 24 bits. Strides and the width
//    are in pixels too. The ST makes software work out a skew and three end
//    masks for every blit; here they fall out of the low three bits of the two
//    addresses and the width, and software never sees them.
//
//  * 32 BITS AT A TIME, eight pixels, because that is the SDRAM word.
//
//  * TRANSPARENCY IS A COLOUR KEY. Planar hardware masks a sprite with a
//    separate one-bit plane and a logic operation; with packed pixels the mask
//    would have to be four bits per pixel, so a "skip this colour" compare is
//    the natural form.
//
// A LINE AT A TIME. Each line is read whole into a buffer -- the source, then
// the destination -- and only then written back. That makes overlapping blits
// safe in the horizontal direction without a right-to-left mode: by the time
// anything is written, everything that line needs has been read. Vertical
// overlap is handled the way the ST does it, by blitting bottom-up: point the
// addresses at the last line and make the strides negative.
//
// It also suits the memory. SDRAM reads come as aligned bursts of four words,
// so the line is read in bursts; writes are single words, and a word whose
// pixels are all skipped is not written at all.
//
// The destination line is always read, even for a plain copy that will
// overwrite every pixel: the partial words at each end of a line need it, and
// treating every word alike keeps the control simple. It costs about a quarter
// of the bandwidth and is the obvious thing to optimise later.
//
// Registers (byte offsets; multi-byte values little-endian):
//
//   $00-$02  SRC         source pixel address
//   $04-$06  DST         destination pixel address
//   $08-$09  SRC_STRIDE  added to SRC after each line, signed
//   $0A-$0B  DST_STRIDE  added to DST after each line, signed
//   $0C-$0D  WIDTH       pixels per line, 1..1024
//   $0E-$0F  HEIGHT      lines, 1..65535
//   $10      OP          logic operation, low four bits (see below)
//   $11      COLOUR      low nibble: fill colour; high nibble: transparent colour
//   $12      CONTROL     write: bit 0 start, bit 1 fill, bit 2 transparent,
//                               bit 3 pattern
//                        read:  bit 7 busy, bits 3-1 as written
//   $13      PAT_Y       bits 2-0: the pattern row for the first line
//   $20-$3F  PATTERN     8 x 8 pixels, row r in bytes 4r..4r+3, the even pixel
//                        of each byte in its low nibble, as the screen has them
//
// With "fill" set the source is the fill colour instead of memory, and SRC and
// SRC_STRIDE are ignored. With "pattern" set the source is the pattern instead
// (it wins over "fill"; SRC and SRC_STRIDE are again ignored): a pixel's column
// in it is its destination pixel address mod 8, and the row is PAT_Y for the
// first line, then the next row, mod 8, for each line after. A destination
// whose line starts and stride are multiples of 8 pixels -- the screen -- so
// has the pattern aligned to its own x mod 8, and PAT_Y = top mod 8 aligns it
// to y too, as QuickDraw aligns patterns. With "transparent" set, source
// pixels equal to the transparent colour leave the destination alone.
//
// OP is a truth table over (source, destination), applied to each bit:
//   bit 0: result where S=1 D=1      bit 2: result where S=0 D=1
//   bit 1: result where S=1 D=0      bit 3: result where S=0 D=0
// so 3 = S (copy), 6 = S xor D, 7 = S or D, 1 = S and D, 12 = not S, 0 = clear,
// 15 = set -- the ST's numbering.
//
// Registers written while a blit is running are ignored. SRC, DST and HEIGHT
// are not changed by a blit, so the same one can be started again. CONTROL,
// PAT_Y and PATTERN read back; the other registers read $FF.
//============================================================================
`default_nettype none

module blitter (
    input  wire        clk,
    input  wire        rst_n,

    // register interface (one-cycle strobe, byte wide)
    input  wire [5:0]  reg_addr,
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,
    input  wire        cs,
    input  wire        we,

    // memory-master port of the SDRAM controller
    output reg         m_req,
    output reg         m_we,
    output reg  [20:0] m_addr,
    output reg  [31:0] m_wdata,
    output wire [3:0]  m_wmask,
    input  wire        m_done,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,

    output wire        busy
);
    assign m_wmask = 4'b1111;         // the destination was merged in already

    //------------------------------------------------------------------
    // Registers
    //------------------------------------------------------------------
    reg [23:0] r_src, r_dst;
    reg [15:0] r_sstride, r_dstride;
    reg [10:0] r_width;
    reg [15:0] r_height;
    reg [3:0]  r_op, r_fill, r_key;
    reg        r_fillmode, r_trans, r_patmode;
    reg [2:0]  r_paty;
    reg [7:0]  r_pat [0:31];          // the pattern, a byte a register

    localparam [3:0] S_IDLE  = 4'd0,  S_LINE   = 4'd1,  S_SETUP  = 4'd2,
                     S_RSRC  = 4'd3,  S_RDST   = 4'd4,  S_RGAP   = 4'd5,
                     S_PRIME = 4'd6,  S_FETCH  = 4'd7,  S_CALC   = 4'd8,
                     S_WRITE = 4'd9,  S_NEXT   = 4'd10, S_PRIME2 = 4'd11;
    reg [3:0] state;
    assign busy = (state != S_IDLE);

    wire start = cs & we & (reg_addr == 6'h12) & wdata[0] & ~busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_src <= 24'd0; r_dst <= 24'd0;
            r_sstride <= 16'd0; r_dstride <= 16'd0;
            r_width <= 11'd0; r_height <= 16'd0;
            r_op <= 4'd3; r_fill <= 4'd0; r_key <= 4'd0;
            r_fillmode <= 1'b0; r_trans <= 1'b0; r_patmode <= 1'b0;
            r_paty <= 3'd0;
        end else if (cs && we && !busy && !reg_addr[5]) begin
            case (reg_addr[4:0])
            5'h00: r_src[7:0]       <= wdata;
            5'h01: r_src[15:8]      <= wdata;
            5'h02: r_src[23:16]     <= wdata;
            5'h04: r_dst[7:0]       <= wdata;
            5'h05: r_dst[15:8]      <= wdata;
            5'h06: r_dst[23:16]     <= wdata;
            5'h08: r_sstride[7:0]   <= wdata;
            5'h09: r_sstride[15:8]  <= wdata;
            5'h0A: r_dstride[7:0]   <= wdata;
            5'h0B: r_dstride[15:8]  <= wdata;
            5'h0C: r_width[7:0]     <= wdata;
            5'h0D: r_width[10:8]    <= wdata[2:0];
            5'h0E: r_height[7:0]    <= wdata;
            5'h0F: r_height[15:8]   <= wdata;
            5'h10: r_op             <= wdata[3:0];
            5'h11: {r_key, r_fill}  <= wdata;
            5'h12: {r_patmode, r_trans, r_fillmode} <= wdata[3:1];
            5'h13: r_paty           <= wdata[2:0];
            default: ;
            endcase
        end
    end

    // The pattern, out of the reset block: it needs none, and is then free to
    // be distributed RAM.
    always @(posedge clk)
        if (cs && we && !busy && reg_addr[5]) r_pat[reg_addr[4:0]] <= wdata;

    always @* begin
        if (reg_addr[5])            rdata = r_pat[reg_addr[4:0]];
        else if (reg_addr == 6'h12) rdata = {busy, 3'b000, r_patmode, r_trans, r_fillmode, 1'b0};
        else if (reg_addr == 6'h13) rdata = {5'd0, r_paty};
        else                        rdata = 8'hFF;
    end

    //------------------------------------------------------------------
    // Line buffers: source and destination, as read. Indexed in words from
    // the aligned start of each burst sequence. 256 words covers the widest
    // line (1024 pixels is 128 words, plus alignment at each end).
    //------------------------------------------------------------------
    reg [31:0] sbuf [0:255];
    reg [31:0] dbuf [0:255];
    reg [31:0] sbuf_q, dbuf_q;
    reg [7:0]  buf_wr;                // write index while reading a line in
    reg [7:0]  s_idx;                 // source buffer word for the current window
    reg [7:0]  j;                     // destination word within the line
    reg        reading_dst;           // the read phase has reached the destination

    //------------------------------------------------------------------
    // Per-line geometry, worked out once per line in S_LINE and S_SETUP.
    //
    // Bursts are aligned to four words, which is 32 pixels, so each line is
    // read starting from its address rounded down to a multiple of 32 and the
    // low five bits of the address say where the line starts in the buffer.
    //------------------------------------------------------------------
    reg [23:0] cur_s, cur_d;          // this line's pixel addresses
    reg [15:0] lines;
    reg [2:0]  prow;                  // this line's pattern row

    wire [4:0]  s_off5 = cur_s[4:0];  // start within the source buffer
    wire [4:0]  d_off5 = cur_d[4:0];
    wire [2:0]  d_off  = cur_d[2:0];  // start within the first destination word

    wire [11:0] s_span = {7'd0, s_off5} + {1'b0, r_width};   // pixels incl. lead-in
    wire [11:0] d_span = {7'd0, d_off5} + {1'b0, r_width};
    wire [11:0] w_span = {9'd0, d_off}  + {1'b0, r_width};

    reg [6:0]  s_bursts, d_bursts;    // bursts to read for each
    reg [7:0]  d_words;               // destination words to write
    reg [2:0]  e_off;                 // last pixel within the last word
    reg [2:0]  sh;                    // source-to-destination shift, in pixels
    reg [6:0]  burst;

    // Source pixel q of the buffer lands on destination pixel q - K + 8 of the
    // line's first word, where K = s_off5 + 8 - d_off (always 1..39). So the
    // window for destination word j starts K - 8 + 8j pixels into the buffer:
    // a constant shift of K mod 8 pixels, and a word index that just counts.
    wire [5:0] k = {1'b0, s_off5} + 6'd8 - {3'd0, d_off};

    //------------------------------------------------------------------
    // The datapath for one destination word.
    //------------------------------------------------------------------
    reg  [31:0] s_lo;                 // source word below the one in sbuf_q
    wire [63:0] s_window = {sbuf_q, s_lo};
    wire [31:0] s_mem    = s_window[{sh, 2'b00} +: 32];
    // A destination word starts at a multiple of 8 pixels, so its pixel p is
    // column p of the pattern: the row is the source word as it stands.
    wire [4:0]  prow4    = {prow, 2'b00};
    wire [31:0] p_word   = {r_pat[prow4 + 5'd3], r_pat[prow4 + 5'd2],
                            r_pat[prow4 + 5'd1], r_pat[prow4]};
    wire [31:0] s_word   = r_patmode  ? p_word :
                           r_fillmode ? {8{r_fill}} : s_mem;
    wire [31:0] d_word   = dbuf_q;

    // Four product terms per bit, selected by the operation.
    wire [31:0] rop = ({32{r_op[0]}} &  s_word &  d_word)
                    | ({32{r_op[1]}} &  s_word & ~d_word)
                    | ({32{r_op[2]}} & ~s_word &  d_word)
                    | ({32{r_op[3]}} & ~s_word & ~d_word);

    wire first_word = (j == 8'd0);
    wire last_word  = (j == d_words - 8'd1);

    reg  [31:0] merged;
    reg         any_en;
    reg         en;
    integer     p;
    always @* begin
        merged = d_word;
        any_en = 1'b0;
        for (p = 0; p < 8; p = p + 1) begin
            en = 1'b1;
            if (first_word && p[2:0] < d_off) en = 1'b0;
            if (last_word  && p[2:0] > e_off) en = 1'b0;
            if (r_trans && s_word[p*4 +: 4] == r_key) en = 1'b0;
            if (en) begin
                merged[p*4 +: 4] = rop[p*4 +: 4];
                any_en = 1'b1;
            end
        end
    end

    //------------------------------------------------------------------
    // Control
    //------------------------------------------------------------------
    // Sign-extended strides, in pixels.
    wire [23:0] sstride_x = {{8{r_sstride[15]}}, r_sstride};
    wire [23:0] dstride_x = {{8{r_dstride[15]}}, r_dstride};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            m_req  <= 1'b0;
            m_we   <= 1'b0;
            m_addr <= 21'd0;
        end else begin
            case (state)
            S_IDLE: begin
                m_req <= 1'b0;
                if (start) begin
                    cur_s <= r_src;
                    cur_d <= r_dst;
                    lines <= r_height;
                    prow  <= r_paty;
                    // A blit with nothing in it is finished before it starts.
                    if (r_width != 11'd0 && r_height != 16'd0) state <= S_LINE;
                end
            end

            // Geometry for this line.
            S_LINE: begin
                s_bursts <= s_span[11:5] + (|s_span[4:0]);
                d_bursts <= d_span[11:5] + (|d_span[4:0]);
                d_words  <= w_span[10:3] + (|w_span[2:0]);
                e_off    <= w_span[2:0] - 3'd1;
                sh       <= k[2:0];
                // Window word for j = 0, relative to the aligned buffer start;
                // -1 when the first window begins before the buffer does, in
                // which case those pixels are masked off anyway.
                s_idx    <= {5'd0, k[5:3]} - 8'd1;
                burst    <= 7'd0;
                buf_wr   <= 8'd0;
                state    <= S_SETUP;
            end

            S_SETUP: begin
                if (r_fillmode || r_patmode) begin
                    m_addr <= {cur_d[23:5], 2'b00};
                    state  <= S_RDST;
                end else begin
                    m_addr <= {cur_s[23:5], 2'b00};
                    state  <= S_RSRC;
                end
                m_we  <= 1'b0;
                m_req <= 1'b1;
            end

            // Read the source line, a burst at a time (the buffers themselves
            // are written further down). After each burst the request is
            // dropped for a cycle so the CPU can get a turn.
            S_RSRC: begin
                if (m_rvalid) buf_wr <= buf_wr + 8'd1;
                if (m_done) begin
                    m_req <= 1'b0;
                    burst <= burst + 7'd1;
                    state <= S_RGAP;
                end
            end

            S_RDST: begin
                if (m_rvalid) buf_wr <= buf_wr + 8'd1;
                if (m_done) begin
                    m_req <= 1'b0;
                    burst <= burst + 7'd1;
                    state <= S_RGAP;
                end
            end

            // Between bursts: carry on with this buffer, move on to the
            // destination, or start writing.
            S_RGAP: begin
                if (!reading_dst && burst != s_bursts) begin
                    m_addr <= m_addr + 21'd4;
                    m_req  <= 1'b1;
                    state  <= S_RSRC;
                end else if (!reading_dst) begin
                    m_addr <= {cur_d[23:5], 2'b00};
                    m_req  <= 1'b1;
                    burst  <= 7'd0;
                    buf_wr <= 8'd0;
                    state  <= S_RDST;
                end else if (burst != d_bursts) begin
                    m_addr <= m_addr + 21'd4;
                    m_req  <= 1'b1;
                    state  <= S_RDST;
                end else begin
                    j     <= 8'd0;
                    state <= S_PRIME;
                end
            end

            // Load the first window's low word, then its high word.
            S_PRIME: begin
                s_idx  <= s_idx + 8'd1;
                state  <= S_PRIME2;
            end
            S_PRIME2: begin
                s_lo  <= sbuf_q;
                state <= S_FETCH;
            end

            S_FETCH: begin
                s_idx  <= s_idx + 8'd1;
                state  <= S_CALC;
            end

            S_CALC: begin
                m_wdata <= merged;
                m_addr  <= cur_d[23:3] + {13'd0, j};
                s_lo    <= sbuf_q;            // this window's high is the next one's low
                if (any_en) begin
                    m_we  <= 1'b1;
                    m_req <= 1'b1;
                    state <= S_WRITE;
                end else begin
                    state <= S_NEXT;          // nothing to change in this word
                end
            end

            S_WRITE: begin
                if (m_done) begin
                    m_req <= 1'b0;
                    m_we  <= 1'b0;
                    state <= S_NEXT;
                end
            end

            S_NEXT: begin
                if (!last_word) begin
                    j     <= j + 8'd1;
                    state <= S_FETCH;
                end else if (lines != 16'd1) begin
                    lines <= lines - 16'd1;
                    prow  <= prow + 3'd1;
                    cur_s <= cur_s + sstride_x;
                    cur_d <= cur_d + dstride_x;
                    state <= S_LINE;
                end else begin
                    state <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // Which buffer the read phase is filling: set once it reaches S_RDST,
    // cleared at the start of each line.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                 reading_dst <= 1'b0;
        else if (state == S_LINE)   reading_dst <= 1'b0;
        else if (state == S_RDST)   reading_dst <= 1'b1;
    end

    // The line buffers, kept out of the reset block above so they are plain
    // synchronous RAMs: one write port and one registered read port each.
    always @(posedge clk) begin
        if (state == S_RSRC && m_rvalid) sbuf[buf_wr] <= m_rdata;
        if (state == S_RDST && m_rvalid) dbuf[buf_wr] <= m_rdata;
        if (state == S_PRIME || state == S_FETCH) sbuf_q <= sbuf[s_idx];
        if (state == S_FETCH) dbuf_q <= dbuf[{6'd0, cur_d[4:3]} + j];
    end
endmodule

`default_nettype wire
