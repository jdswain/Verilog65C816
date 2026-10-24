//============================================================================
// dma.v -- two-channel DMA engine for the carrier's 53C80 and 82077AA
//
// docs/DMA.md is the specification; this is its engine. Channel 0 serves the
// 53C80 (DRQ0, /DACK on bus slot 4), channel 1 the 82077AA (DRQ1, slot 1).
// Each moves one byte per external bus cycle between its device and SDRAM.
//
// REGISTERS, 16 bytes a channel (reg_addr[4] picks it):
//   +0..+2 ADDR    the next byte's address, low first
//   +4..+6 COUNT   the bytes left
//   +8     CTRL    0 EN, 1 DIR (1 = memory to device), 2 TC on the last
//                  byte, 3 IE
//   +9     STATUS  7 BUSY, 6 DRQ (synchronised), 0 DONE (write 1 to clear)
// ADDR and COUNT are written only while the channel is not BUSY. A CTRL
// write always sets IE; EN = 0 stops the channel; EN = 1 starts it only if
// it is not BUSY (it keeps it running if it is). DIR and TC are taken when
// it starts.
//
// THE BUS. A channel asks for a cycle when it is enabled, has bytes left,
// its DRQ is high and has been looked at afresh (DRQ_HOLD clocks after its
// last cycle ended, for the synchroniser), and its data is ready: for memory
// to device the byte is in its line buffer, for device to memory its write
// queue can take the word this byte would finish. With both asking, they
// take turns.
//
// THE MEMORY. One master on port 2, behind mm_mux. Device to memory: bytes
// are gathered into a word with a byte mask, which moves to a one-word queue
// when its last byte is filled, when COUNT reaches 0, or when the channel is
// stopped; the queue is written while the next word gathers. Memory to
// device: a 16-byte line buffer, one burst, fetched when the next byte is not
// in it. A fetch waits while the cache has a posted store in flight
// (wr_busy), so a buffer the CPU has just filled is read as written.
//
// DONE is set when COUNT is 0 and every byte is in memory (or out on the
// bus); BUSY covers that, plus a bus cycle or memory operation still under
// way, so ADDR and COUNT are final once BUSY is clear.
//============================================================================
`default_nettype none

module dma #(
    parameter [2:0] SLOT0    = 3'd4,     // 53C80 /DACK
    parameter [2:0] SLOT1    = 3'd1,     // 82077AA /DACK
    parameter integer DRQ_HOLD = 2       // clocks after a cycle before DRQ counts
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- CPU registers ----
    input  wire [4:0]  reg_addr,
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,            // combinational from reg_addr
    input  wire        cs,               // one-cycle strobe
    input  wire        we,
    output wire        irq,
    output wire [1:0]  irq_ch,           // each channel's DONE & IE, for $0440

    // ---- devices ----
    input  wire [1:0]  drq,              // asynchronous, active high

    // ---- external bus (external_bus.v's DMA port) ----
    output reg         b_req,
    output reg         b_we,             // 1 = WR# (memory to device)
    output reg  [2:0]  b_slot,
    output reg         b_tc,
    output reg  [7:0]  b_wdata,
    input  wire [7:0]  b_rdata,
    input  wire        b_ack,

    // ---- memory (port 2 through mm_mux) ----
    output reg         m_req,
    output reg         m_we,
    output reg  [20:0] m_addr,
    output reg  [31:0] m_wdata,
    output reg  [3:0]  m_wmask,
    input  wire        m_done,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,

    input  wire        wr_busy           // the cache has a store in flight
);
    integer c;

    //------------------------------------------------------------------
    // Channel state. Wide fields are packed vectors indexed [c*W +: W], so
    // nothing here looks like a RAM to synthesis.
    //------------------------------------------------------------------
    reg [47:0]  addr_v;                  // 2 x 24
    reg [47:0]  cnt_v;                   // 2 x 24
    reg [1:0]   en, dir, tc, ie, done;
    // device to memory: the word being gathered, and the queue
    reg [63:0]  gd_v;  reg [7:0] gm_v;  reg [41:0] gw_v;
    reg [63:0]  qd_v;  reg [7:0] qm_v;  reg [41:0] qw_v;
    reg [1:0]   q_full;
    // memory to device: the line buffer
    reg [255:0] lb_v;  reg [37:0] lt_v;  reg [1:0] lb_ok;
    reg [3:0]   hold_v;                  // 2 x 2: DRQ hold-off

    // DRQ comes from the carrier unsynchronised.
    reg [1:0] drq_m, drq_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin drq_m <= 2'b00; drq_s <= 2'b00; end
        else        begin drq_m <= drq;   drq_s <= drq_m; end
    end

    // Bus side
    reg       b_busy;                    // a cycle is under way
    reg       b_ch;                      // for this channel
    reg       last;                      // the channel that had the last cycle
    // Memory side
    localparam [1:0] M_IDLE = 2'd0, M_BUSY = 2'd1, M_GAP = 2'd2;
    reg [1:0]  mstate;
    reg        m_ch;
    reg [1:0]  beat;
    reg [18:0] ftag;                     // the line being fetched

    //------------------------------------------------------------------
    // Per-channel conditions
    //------------------------------------------------------------------
    reg [1:0] cnt_nz, cnt_one, lb_hit, ends_word, can_bus, need_fetch,
              busy, b_on, m_on;
    always @* begin
        for (c = 0; c < 2; c = c + 1) begin
            cnt_nz[c]    = cnt_v[c*24 +: 24] != 24'd0;
            cnt_one[c]   = cnt_v[c*24 +: 24] == 24'd1;
            lb_hit[c]    = lb_ok[c] & (lt_v[c*19 +: 19] == addr_v[c*24+4 +: 19]);
            ends_word[c] = (addr_v[c*24 +: 2] == 2'd3) | cnt_one[c];
            b_on[c]      = b_busy & (b_ch == c);
            m_on[c]      = (mstate != M_IDLE) & (m_ch == c);
            can_bus[c]   = en[c] & cnt_nz[c] & drq_s[c]
                         & (hold_v[c*2 +: 2] == 2'd0) & ~b_on[c]
                         & (dir[c] ? lb_hit[c] : ~(q_full[c] & ends_word[c]));
            need_fetch[c] = en[c] & dir[c] & cnt_nz[c] & ~lb_hit[c] & ~wr_busy;
            busy[c]      = en[c] | (gm_v[c*4 +: 4] != 4'd0) | q_full[c]
                         | b_on[c] | m_on[c];
        end
    end

    assign irq_ch = done & ie;
    assign irq    = |irq_ch;

    //------------------------------------------------------------------
    // Register reads
    //------------------------------------------------------------------
    wire rc = reg_addr[4];
    always @* begin
        case (reg_addr[3:0])
        4'h0: rdata = addr_v[rc*24 +: 8];
        4'h1: rdata = addr_v[rc*24+8 +: 8];
        4'h2: rdata = addr_v[rc*24+16 +: 8];
        4'h4: rdata = cnt_v[rc*24 +: 8];
        4'h5: rdata = cnt_v[rc*24+8 +: 8];
        4'h6: rdata = cnt_v[rc*24+16 +: 8];
        4'h8: rdata = {4'd0, ie[rc], tc[rc], dir[rc], en[rc]};
        4'h9: rdata = {busy[rc], drq_s[rc], 5'd0, done[rc]};
        default: rdata = 8'h00;
        endcase
    end

    //------------------------------------------------------------------
    // The byte a bus cycle delivers, merged into its channel's gather word
    //------------------------------------------------------------------
    wire [1:0]  lane    = addr_v[b_ch*24 +: 2];
    wire [31:0] gd_cur  = gd_v[b_ch*32 +: 32];
    wire [31:0] gd_new  = (lane == 2'd0) ? {gd_cur[31:8], b_rdata} :
                          (lane == 2'd1) ? {gd_cur[31:16], b_rdata, gd_cur[7:0]} :
                          (lane == 2'd2) ? {gd_cur[31:24], b_rdata, gd_cur[15:0]} :
                                           {b_rdata, gd_cur[23:0]};
    wire [3:0]  gm_new  = gm_v[b_ch*4 +: 4] | (4'b0001 << lane);

    // Which channel gets the next bus cycle
    wire pick = (can_bus[0] & can_bus[1]) ? ~last : can_bus[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_v <= 48'd0; cnt_v <= 48'd0;
            en <= 2'b00; dir <= 2'b00; tc <= 2'b00; ie <= 2'b00; done <= 2'b00;
            gd_v <= 64'd0; gm_v <= 8'd0; gw_v <= 42'd0;
            qd_v <= 64'd0; qm_v <= 8'd0; qw_v <= 42'd0; q_full <= 2'b00;
            lb_v <= 256'd0; lt_v <= 38'd0; lb_ok <= 2'b00;
            hold_v <= 4'd0;
            b_req <= 1'b0; b_we <= 1'b0; b_slot <= 3'd0; b_tc <= 1'b0;
            b_wdata <= 8'd0; b_busy <= 1'b0; b_ch <= 1'b0; last <= 1'b0;
            mstate <= M_IDLE; m_ch <= 1'b0; beat <= 2'd0; ftag <= 19'd0;
            m_req <= 1'b0; m_we <= 1'b0; m_addr <= 21'd0;
            m_wdata <= 32'd0; m_wmask <= 4'd0;
        end else begin
            for (c = 0; c < 2; c = c + 1)
                if (hold_v[c*2 +: 2] != 2'd0) hold_v[c*2 +: 2] <= hold_v[c*2 +: 2] - 2'd1;

            //----------------------------------------------------------
            // Ending: a stopped channel's partial word goes to the queue;
            // a finished one sets DONE.
            //----------------------------------------------------------
            for (c = 0; c < 2; c = c + 1) begin
                if (~en[c] & (gm_v[c*4 +: 4] != 4'd0) & ~q_full[c] & ~b_on[c]) begin
                    qd_v[c*32 +: 32] <= gd_v[c*32 +: 32];
                    qm_v[c*4 +: 4]   <= gm_v[c*4 +: 4];
                    qw_v[c*21 +: 21] <= gw_v[c*21 +: 21];
                    q_full[c]        <= 1'b1;
                    gm_v[c*4 +: 4]   <= 4'd0;
                end
                if (en[c] & ~cnt_nz[c] & (gm_v[c*4 +: 4] == 4'd0) & ~q_full[c]
                          & ~b_on[c] & ~m_on[c]) begin
                    en[c]   <= 1'b0;
                    done[c] <= 1'b1;
                end
            end

            //----------------------------------------------------------
            // Bus cycles
            //----------------------------------------------------------
            if (!b_busy) begin
                if (can_bus != 2'b00) begin
                    b_busy  <= 1'b1;
                    b_ch    <= pick;
                    b_req   <= 1'b1;
                    b_we    <= dir[pick];
                    b_slot  <= pick ? SLOT1 : SLOT0;
                    b_tc    <= tc[pick] & cnt_one[pick];
                    b_wdata <= lb_v[pick*128 + addr_v[pick*24 +: 4]*8 +: 8];
                end
            end else if (b_ack) begin
                b_req  <= 1'b0;
                b_tc   <= 1'b0;
                b_busy <= 1'b0;
                last   <= b_ch;
                hold_v[b_ch*2 +: 2] <= DRQ_HOLD[1:0];
                addr_v[b_ch*24 +: 24] <= addr_v[b_ch*24 +: 24] + 24'd1;
                cnt_v[b_ch*24 +: 24]  <= cnt_v[b_ch*24 +: 24] - 24'd1;
                if (!dir[b_ch]) begin
                    if (gm_v[b_ch*4 +: 4] == 4'd0)
                        gw_v[b_ch*21 +: 21] <= addr_v[b_ch*24+2 +: 21];
                    if (ends_word[b_ch]) begin
                        // The word is complete (or the transfer is): queue it.
                        qd_v[b_ch*32 +: 32] <= gd_new;
                        qm_v[b_ch*4 +: 4]   <= gm_new;
                        qw_v[b_ch*21 +: 21] <= (gm_v[b_ch*4 +: 4] == 4'd0)
                                             ? addr_v[b_ch*24+2 +: 21]
                                             : gw_v[b_ch*21 +: 21];
                        q_full[b_ch]        <= 1'b1;
                        gm_v[b_ch*4 +: 4]   <= 4'd0;
                    end else begin
                        gd_v[b_ch*32 +: 32] <= gd_new;
                        gm_v[b_ch*4 +: 4]   <= gm_new;
                    end
                end
            end

            //----------------------------------------------------------
            // Memory: one transaction at a time, queued writes first. The
            // request is held through `done` and dropped for a cycle after.
            //----------------------------------------------------------
            case (mstate)
            M_IDLE: begin
                if (q_full != 2'b00) begin
                    m_ch    <= q_full[1];
                    m_we    <= 1'b1;
                    m_addr  <= qw_v[q_full[1]*21 +: 21];
                    m_wdata <= qd_v[q_full[1]*32 +: 32];
                    m_wmask <= qm_v[q_full[1]*4 +: 4];
                    m_req   <= 1'b1;
                    mstate  <= M_BUSY;
                end else if (need_fetch != 2'b00) begin
                    m_ch    <= need_fetch[1];
                    m_we    <= 1'b0;
                    m_addr  <= {addr_v[need_fetch[1]*24+4 +: 19], 2'b00};
                    ftag    <= addr_v[need_fetch[1]*24+4 +: 19];
                    m_wmask <= 4'hF;
                    beat    <= 2'd0;
                    m_req   <= 1'b1;
                    mstate  <= M_BUSY;
                end
            end
            M_BUSY: begin
                if (m_rvalid & ~m_we) begin
                    lb_v[m_ch*128 + beat*32 +: 32] <= m_rdata;
                    beat <= beat + 2'd1;
                end
                if (m_done) begin
                    m_req <= 1'b0;
                    if (m_we) q_full[m_ch] <= 1'b0;
                    else begin
                        lb_ok[m_ch]          <= 1'b1;
                        lt_v[m_ch*19 +: 19]  <= ftag;
                    end
                    mstate <= M_GAP;
                end
            end
            default: mstate <= M_IDLE;
            endcase

            //----------------------------------------------------------
            // CPU writes, last so that they win
            //----------------------------------------------------------
            if (cs & we) begin
                case (reg_addr[3:0])
                4'h0: if (!busy[rc]) addr_v[rc*24 +: 8]    <= wdata;
                4'h1: if (!busy[rc]) addr_v[rc*24+8 +: 8]  <= wdata;
                4'h2: if (!busy[rc]) addr_v[rc*24+16 +: 8] <= wdata;
                4'h4: if (!busy[rc]) cnt_v[rc*24 +: 8]     <= wdata;
                4'h5: if (!busy[rc]) cnt_v[rc*24+8 +: 8]   <= wdata;
                4'h6: if (!busy[rc]) cnt_v[rc*24+16 +: 8]  <= wdata;
                4'h8: begin
                    ie[rc] <= wdata[3];
                    if (!wdata[0])
                        en[rc] <= 1'b0;
                    else if (!busy[rc]) begin
                        en[rc]    <= 1'b1;
                        dir[rc]   <= wdata[1];
                        tc[rc]    <= wdata[2];
                        done[rc]  <= 1'b0;
                        lb_ok[rc] <= 1'b0;   // memory may have changed
                    end
                end
                4'h9: if (wdata[0]) done[rc] <= 1'b0;
                default: ;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
