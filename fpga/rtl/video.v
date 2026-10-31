//============================================================================
// video.v -- 640x480 or 1024x768 display scanned out of SDRAM: 4bpp graphics
// or text
//
// The resolution is chosen when building (XGA, from `make bit RES=1024`): the
// pixel clock differs, 25.2 or 64.8 MHz (video_pll.v), and nothing else does
// but the sizes.
//
// GRAPHICS: 4 bits per pixel through a 16-entry palette: 320 bytes per line,
// 150 KB for the frame, and 9.2 MB/s of read bandwidth -- about a tenth of what
// the burst controller sustains at 45 MHz, leaving the rest for the CPU. At
// 1024x768 a line is 512 bytes, the frame 384 KB, and the bandwidth 23.6 MB/s.
//
// TEXT: 80 x 30 cells of 8x16 pixels (128 x 48 at 1024x768). A cell is two bytes, the character code
// then an attribute {background[3:0], foreground[3:0]}, both colours going
// through the same palette. A row is 160 bytes and the screen 4800, at the same
// base address as the graphics frame (256 and 12288 at 1024x768). The glyphs come from a 4 KB font ROM
// addressed by {character, row within the cell}.
//
// Text reuses the graphics fetch unchanged apart from its length: each scanline
// still fetches its own data into the line buffer, so a row of text is simply
// read 16 times. That costs half the bandwidth of graphics and needs no second
// buffer; the only new hardware is the font ROM and one pipeline stage for it.
//
// WRITTEN FOR TWO CLOCK DOMAINS. On the board `clk` and `clk_pix` are the same
// 25.2 MHz clock (see top_tang20k.v), but nothing here relies on that. The line
// buffer is the crossing: written as 32-bit words on the memory clock, read as
// pixels on the pixel clock, which is exactly what a dual-port block RAM does
// natively. The only control that crosses is the line/frame pulse, and it goes
// through a toggle and two flops rather than being used raw.
//
// DOUBLE BUFFERED, by line parity. Line y is displayed out of half y[0] while
// line y+1 is being fetched into the other half, so a fetch never races the
// scan. Nothing needs to signal a swap: both sides derive the half from the
// line number they are already tracking.
//============================================================================
`default_nettype none

module video #(
    parameter XGA = 0,                  // 1 = 1024x768, else 640x480
    // Framebuffer base as an SDRAM *word* address. Default $700000 bytes
    // (bank $70), well clear of where the CPU runs.
    parameter [20:0] FB_WORD_BASE = 21'h1C0000,
    // Font image: 4096 bytes, one per line, glyph after glyph (tools/mkfont.py).
    // Synthesis needs an absolute path here, for the same reason the boot ROM
    // does -- see rom_path.vh. The default suits a simulation run from fpga/.
    parameter FONT_HEX = "rom/font_st8x16.hex"
) (
    // memory-side domain
    input  wire        clk,
    input  wire        rst_n,
    output reg         m_req,
    output wire        m_we,
    output reg  [20:0] m_addr,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wmask,
    input  wire        m_done,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,

    // pixel-side domain
    input  wire        clk_pix,
    input  wire        pix_rst_n,
    output reg  [7:0]  red,
    output reg  [7:0]  green,
    output reg  [7:0]  blue,
    output reg         hsync,
    output reg         vsync,
    output reg         de,

    // Palette writes, one byte at a time -- the CPU has an 8-bit bus, so a
    // 24-bit port would need shadow registers in the decoder.
    input  wire        pal_we,
    input  wire [3:0]  pal_idx,
    input  wire [1:0]  pal_sel,     // 0 = red, 1 = green, 2 = blue
    input  wire [7:0]  pal_byte,

    // 0 = graphics, 1 = text. Memory domain; each side samples it at the top
    // of a frame, so a change never lands part-way down the screen.
    input  wire        text_mode
);
    localparam integer WORDS_PER_LINE = XGA ? 128 : 80;   // px * 4 bits / 32
    localparam integer WORDS_PER_ROW  = XGA ?  64 : 40;   // cells * 16 bits / 32
    localparam integer LINES          = XGA ? 768 : 480;

    assign m_we    = 1'b0;                      // video only ever reads
    assign m_wdata = 32'd0;
    assign m_wmask = 4'd0;

    //------------------------------------------------------------------
    // Pixel-side timing
    //------------------------------------------------------------------
    wire [10:0] x;
    wire [9:0]  y;
    wire       t_hsync, t_vsync, t_de, t_line_start, t_frame_start;

    video_timing #(.XGA(XGA)) u_tim (
        .clk(clk_pix), .rst_n(pix_rst_n),
        .x(x), .y(y), .active_x(), .active_y(),
        .hsync(t_hsync), .vsync(t_vsync), .de(t_de),
        .line_start(t_line_start), .frame_start(t_frame_start)
    );

    //------------------------------------------------------------------
    // Cross the line and frame pulses into the memory domain. A pulse one
    // pixel-clock wide would be missed or double-sampled; a toggle survives.
    //------------------------------------------------------------------
    reg line_tog = 1'b0, frame_tog = 1'b0;
    always @(posedge clk_pix or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            line_tog  <= 1'b0;
            frame_tog <= 1'b0;
        end else begin
            if (t_line_start)  line_tog  <= ~line_tog;
            if (t_frame_start) frame_tog <= ~frame_tog;
        end
    end

    reg [2:0] line_sync, frame_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_sync  <= 3'd0;
            frame_sync <= 3'd0;
        end else begin
            line_sync  <= {line_sync[1:0],  line_tog};
            frame_sync <= {frame_sync[1:0], frame_tog};
        end
    end
    wire line_pulse  = line_sync[2]  ^ line_sync[1];
    wire frame_pulse = frame_sync[2] ^ frame_sync[1];

    //------------------------------------------------------------------
    // Line buffer: two halves, written on clk, read on clk_pix.
    //
    // The half is selected by concatenation, which strides by 128 rather than
    // by the 80 words a 640-pixel line actually uses -- so the array must be
    // 2*128, not 2*80. Sized at 2*80 the upper half runs off the end after 32
    // words, and every odd line loses everything past pixel 256. The slack
    // costs nothing: 256 x 32 bits still fits in a single block RAM, and a
    // 1024-pixel line uses all 128.
    //------------------------------------------------------------------
    localparam integer BUF_STRIDE = 128;
    reg [31:0] lbuf [0:2*BUF_STRIDE-1];
    reg [31:0] lbuf_q;

    //------------------------------------------------------------------
    // Fetch engine (memory domain)
    //------------------------------------------------------------------
    reg [9:0]  fetch_line;
    reg [7:0]  wcount;                // 0..WORDS_PER_LINE within the line
    reg        fetching;
    reg        resume;                // ask for the line's next burst now
    reg        fetch_text;            // mode for the frame being fetched
    reg [20:0] line_base;             // word address of the line being fetched
    wire       fetch_half = fetch_line[0];

    // Where line `n` starts. In text mode all 16 scanlines of a row share one
    // address, which is the whole of the difference between the two modes here.
    wire [9:0]  next_line  = fetch_line + 1'b1;
    wire [20:0] next_base  = FB_WORD_BASE +
                             (fetch_text ? next_line[9:4] * WORDS_PER_ROW
                                         : next_line * WORDS_PER_LINE);
    wire [7:0]  line_words = fetch_text ? WORDS_PER_ROW : WORDS_PER_LINE;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_req      <= 1'b0;
            m_addr     <= 21'd0;
            fetch_line <= 10'd0;
            wcount     <= 8'd0;
            fetching   <= 1'b0;
            resume     <= 1'b0;
            fetch_text <= 1'b0;
            line_base  <= 21'd0;
        end else begin
            resume <= 1'b0;
            if (frame_pulse) begin
                // About to display line 0: fetch it into half 0.
                // Line 0 starts at the base in either mode.
                fetch_line <= 10'd0;
                wcount     <= 8'd0;
                fetching   <= 1'b1;
                fetch_text <= text_mode;
                line_base  <= FB_WORD_BASE;
                m_addr     <= FB_WORD_BASE;
                m_req      <= 1'b1;
            end else if (line_pulse) begin
                if (fetch_line < LINES - 1) begin
                    fetch_line <= next_line;
                    wcount     <= 8'd0;
                    fetching   <= 1'b1;
                    line_base  <= next_base;
                    m_addr     <= next_base;
                    m_req      <= 1'b1;
                end else begin
                    fetching <= 1'b0;
                    m_req    <= 1'b0;
                end
            end else if (fetching) begin
                if (m_rvalid) begin
                    lbuf[{fetch_half, wcount[6:0]}] <= m_rdata;
                    wcount <= wcount + 1'b1;
                end
                if (m_done) begin
                    // The next burst of four words in this line, a cycle
                    // later: video outranks the CPU at the controller, and
                    // asking again at once would lock it out for the whole
                    // line (32 bursts at 1024x768). With the request down
                    // for a cycle the CPU's waiting access goes in between.
                    // A line has its whole line time to be fetched, and
                    // needs about a third of it even so.
                    m_req <= 1'b0;
                    if (wcount >= line_words) begin
                        fetching <= 1'b0;
                    end else begin
                        m_addr <= line_base + wcount;
                        resume <= 1'b1;
                    end
                end else if (resume)
                    m_req <= 1'b1;
            end else begin
                m_req <= 1'b0;
            end
        end
    end

    //------------------------------------------------------------------
    // Palette (written from the memory domain, read from the pixel domain --
    // software only changes it during blanking, so no crossing is needed).
    //------------------------------------------------------------------
    reg [23:0] palette [0:15];
    integer i;
    initial begin
        // A default 16-colour set so something is visible before software
        // writes its own.
        palette[0]  = 24'h000000; palette[1]  = 24'h0000AA;
        palette[2]  = 24'h00AA00; palette[3]  = 24'h00AAAA;
        palette[4]  = 24'hAA0000; palette[5]  = 24'hAA00AA;
        palette[6]  = 24'hAA5500; palette[7]  = 24'hAAAAAA;
        palette[8]  = 24'h555555; palette[9]  = 24'h5555FF;
        palette[10] = 24'h55FF55; palette[11] = 24'h55FFFF;
        palette[12] = 24'hFF5555; palette[13] = 24'hFF55FF;
        palette[14] = 24'hFFFF55; palette[15] = 24'hFFFFFF;
    end
    always @(posedge clk) if (pal_we) begin
        case (pal_sel)
        2'd0: palette[pal_idx][23:16] <= pal_byte;   // red
        2'd1: palette[pal_idx][15:8]  <= pal_byte;   // green
        2'd2: palette[pal_idx][7:0]   <= pal_byte;   // blue
        default: ;
        endcase
    end

    //------------------------------------------------------------------
    // Font ROM: 256 glyphs x 16 rows, one byte per row, bit 7 leftmost.
    // Registered read, so it maps onto block RAM.
    //------------------------------------------------------------------
    reg [7:0] font [0:4095];
    initial $readmemh(FONT_HEX, font);

    //------------------------------------------------------------------
    // Pixel output (pixel domain). Three stages -- line buffer, font ROM,
    // palette -- with the syncs delayed to match. Graphics does not need the
    // middle stage but goes through it anyway, so both modes have the same
    // latency and the picture does not shift when the mode changes.
    //------------------------------------------------------------------
    reg pix_text;                     // mode for the frame being displayed
    always @(posedge clk_pix or negedge pix_rst_n) begin
        if (!pix_rst_n)         pix_text <= 1'b0;
        else if (t_frame_start) pix_text <= text_mode;
    end

    // Graphics: 8 pixels per word. Text: 2 cells, i.e. 16 pixels, per word.
    // (x is below 1024 while displaying, so x[9:3] covers either width.)
    wire        disp_half = y[0];
    wire [6:0]  word_idx  = pix_text ? {1'b0, x[9:4]} : x[9:3];

    // Stage 1: line buffer.
    reg  [3:0]  sub_r;                // x within the word (bit 3: which cell)
    reg  [3:0]  row_r;                // scanline within the text row
    reg         de_r, hs_r, vs_r;

    always @(posedge clk_pix) begin
        lbuf_q <= lbuf[{disp_half, word_idx}];
        sub_r  <= x[3:0];
        row_r  <= y[3:0];
        de_r   <= t_de;
        hs_r   <= t_hsync;
        vs_r   <= t_vsync;
    end

    reg [3:0] nib;
    always @* begin
        case (sub_r[2:0])
        3'd0: nib = lbuf_q[3:0];
        3'd1: nib = lbuf_q[7:4];
        3'd2: nib = lbuf_q[11:8];
        3'd3: nib = lbuf_q[15:12];
        3'd4: nib = lbuf_q[19:16];
        3'd5: nib = lbuf_q[23:20];
        3'd6: nib = lbuf_q[27:24];
        3'd7: nib = lbuf_q[31:28];
        endcase
    end

    // The cell under the beam: low half of the word is the left cell, and
    // within a cell the character is the low byte, the attribute the high.
    wire [15:0] tcell = sub_r[3] ? lbuf_q[31:16] : lbuf_q[15:0];

    // Stage 2: font ROM.
    reg  [7:0]  font_q;
    reg  [7:0]  attr_q;
    reg  [3:0]  nib_q;
    reg  [2:0]  sub_q;
    reg         de_q, hs_q, vs_q;

    always @(posedge clk_pix) begin
        font_q <= font[{tcell[7:0], row_r}];
        attr_q <= tcell[15:8];
        nib_q  <= nib;
        sub_q  <= sub_r[2:0];
        de_q   <= de_r;
        hs_q   <= hs_r;
        vs_q   <= vs_r;
    end

    // Stage 3: palette.
    wire       glyph_bit = font_q[3'd7 - sub_q];
    wire [3:0] colour    = !pix_text ? nib_q :
                           glyph_bit ? attr_q[3:0] : attr_q[7:4];

    always @(posedge clk_pix) begin
        {red, green, blue} <= de_q ? palette[colour] : 24'h000000;
        de    <= de_q;
        hsync <= hs_q;
        vsync <= vs_q;
    end
endmodule

`default_nettype wire
