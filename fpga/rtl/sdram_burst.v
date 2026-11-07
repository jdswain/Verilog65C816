//============================================================================
// sdram_burst.v -- multi-master burst SDRAM controller for the GW2AR-18 die
//
// Replaces the single-access controller. Three things it does differently,
// all of them needed once a display shares the memory:
//
//  1. BURSTS. Reads return four 32-bit words (16 bytes) for one command
//     sequence. The old controller spent ~6 cycles to deliver one byte while
//     the die moved four and discarded three; that capped throughput at
//     4.5 MB/s, which is below what even a 4bpp 640x480 display needs.
//
//  2. OPEN ROWS. Rows are left open per bank instead of auto-precharging every
//     access. Sequential traffic within a 1 KB row then costs only READ+CAS,
//     and because the die has four banks the CPU and the display can each keep
//     a row open without evicting the other's.
//
//  3. THREE MASTERS with fixed priority: port 0, then port 2, then port 1.
//     Port 0 is the display, which has a deadline -- a late line is visible.
//     Port 1 is the CPU's cache, which has none: a late instruction fetch is
//     merely slow. Port 2 is the MEMORY-MASTER port, for anything else that
//     reads and writes memory by itself (the blitter; later, DMA).
//
//     Port 2 outranks the CPU, so a master that re-requests the moment its
//     transaction finishes would lock the CPU out. It must drop `req` for a
//     cycle after each `done`; the CPU then gets one transaction in between
//     each of the master's, which is all the fairness there is. Writes made
//     through port 2 bypass the CPU's cache, so the cache snoops them -- see
//     the invalidation input on cache.v.
//
// Port protocol: raise `req` with `addr`/`we` and hold it. Reads return four
// words, each flagged by `rvalid`; writes take one word with `wmask` byte
// enables. `done` pulses for one cycle when the transaction is finished, after
// which `req` may drop or immediately describe the next transaction.
//
// Writes are single-location (mode register M9) so the burst length applies to
// reads only -- a write-through cache issues many single-word writes and must
// not disturb three neighbours.
//============================================================================
`default_nettype none

module sdram_burst #(
    parameter integer FREQ = 27_000_000
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- master port 0 (higher priority: video) ----
    input  wire        p0_req,
    input  wire        p0_we,
    input  wire [20:0] p0_addr,      // word address
    input  wire [31:0] p0_wdata,
    input  wire [3:0]  p0_wmask,
    output reg         p0_done,
    output reg         p0_rvalid,

    // ---- master port 1 (lower priority: CPU cache) ----
    input  wire        p1_req,
    input  wire        p1_we,
    input  wire [20:0] p1_addr,
    input  wire [31:0] p1_wdata,
    input  wire [3:0]  p1_wmask,
    output reg         p1_done,
    output reg         p1_rvalid,

    // ---- port 2: memory masters (blitter, DMA) ----
    input  wire        p2_req,
    input  wire        p2_we,
    input  wire [20:0] p2_addr,
    input  wire [31:0] p2_wdata,
    input  wire [3:0]  p2_wmask,
    output reg         p2_done,
    output reg         p2_rvalid,

    // shared read data (the granted port's rvalid qualifies it)
    output reg  [31:0] rdata,
    output wire        init_done,

    // ---- SDRAM ----
    output reg  [10:0] sdram_a,
    output reg  [1:0]  sdram_ba,
    inout  wire [31:0] sdram_dq,
    output reg  [3:0]  sdram_dqm,
    output wire        sdram_cs_n,
    output reg         sdram_ras_n,
    output reg         sdram_cas_n,
    output reg         sdram_we_n,
    output wire        sdram_cke
);
    localparam integer CAS       = 2;
    localparam integer BURST     = 4;    // words per read burst
    localparam integer T_RP      = 2;
    localparam integer T_RCD     = 2;
    localparam integer T_RC      = 4;
    localparam integer T_WR      = 2;
    localparam integer T_MRD     = 3;
    localparam integer REFRESH_INTERVAL = (FREQ / 133_000);
    localparam integer INIT_WAIT = (FREQ / 5_000);

    localparam [2:0] CMD_NOP       = 3'b111, CMD_ACTIVE = 3'b011,
                     CMD_READ      = 3'b101, CMD_WRITE  = 3'b100,
                     CMD_PRECHARGE = 3'b010, CMD_REFRESH= 3'b001,
                     CMD_LOADMODE  = 3'b000;

    // burst 4, sequential, CAS 2, single-location writes (M9 = 1)
    localparam [10:0] MODE_REG = {1'b0, 1'b1, 2'b00, 3'd2, 1'b0, 3'b010};

    assign sdram_cs_n = 1'b0;
    assign sdram_cke  = 1'b1;

    //------------------------------------------------------------------
    // Arbitration: port 0 wins. The winner is latched for the whole
    // transaction so a higher-priority request cannot steal it mid-burst.
    //------------------------------------------------------------------
    reg  [1:0] sel;                  // which port holds the controller
    wire       any_req = p0_req | p1_req | p2_req;
    wire [1:0] nxt_sel = p0_req ? 2'd0 : p2_req ? 2'd2 : 2'd1;

    wire        c_we    = sel[1] ? p2_we    : sel[0] ? p1_we    : p0_we;
    wire [20:0] c_addr  = sel[1] ? p2_addr  : sel[0] ? p1_addr  : p0_addr;
    wire [31:0] c_wdata = sel[1] ? p2_wdata : sel[0] ? p1_wdata : p0_wdata;
    wire [3:0]  c_wmask = sel[1] ? p2_wmask : sel[0] ? p1_wmask : p0_wmask;

    // {row, bank, column}: sequential words stay inside one row
    wire [10:0] req_row  = c_addr[20:10];
    wire [1:0]  req_bank = c_addr[9:8];
    wire [7:0]  req_col  = c_addr[7:0];

    //------------------------------------------------------------------
    reg         dq_oe;
    reg  [31:0] dq_out;
    assign sdram_dq = dq_oe ? dq_out : 32'hzzzz_zzzz;

    reg [10:0] open_row [0:3];
    reg [3:0]  row_open;

    localparam [3:0] S_INIT_WAIT = 4'd0, S_INIT_PRE = 4'd1, S_INIT_REF = 4'd2,
                     S_INIT_MODE = 4'd3, S_IDLE     = 4'd4, S_PRE      = 4'd5,
                     S_ACT       = 4'd6, S_READ     = 4'd7, S_RDATA    = 4'd8,
                     S_WRITE     = 4'd9, S_WDONE    = 4'd10,
                     S_REF_PRE   = 4'd11, S_REFRESH = 4'd12, S_DONE     = 4'd13,
                     S_GAP       = 4'd14;

    reg [3:0]  state;
    reg [15:0] delay;
    reg [3:0]  init_refresh;
    reg [15:0] refresh_timer;
    reg        refresh_pending;
    reg        done_flag;
    reg [2:0]  beat;
    reg [1:0]  latched_sel;

    assign init_done = done_flag;

    integer k;

    // A row must be closed before refresh, and re-activated afterwards.
    wire       bank_hit  = row_open[req_bank] & (open_row[req_bank] == req_row);
    wire       bank_busy = row_open[req_bank];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_INIT_WAIT;
            delay           <= INIT_WAIT[15:0];
            init_refresh    <= 4'd0;
            refresh_timer   <= 16'd0;
            refresh_pending <= 1'b0;
            done_flag       <= 1'b0;
            beat            <= 3'd0;
            sel             <= 2'd0;
            latched_sel     <= 2'd0;
            dq_oe           <= 1'b0;
            dq_out          <= 32'd0;
            rdata           <= 32'd0;
            p0_done         <= 1'b0;
            p1_done         <= 1'b0;
            p2_done         <= 1'b0;
            p0_rvalid       <= 1'b0;
            p1_rvalid       <= 1'b0;
            p2_rvalid       <= 1'b0;
            sdram_a         <= 11'd0;
            sdram_ba        <= 2'd0;
            sdram_dqm       <= 4'b1111;
            row_open        <= 4'b0000;
            for (k = 0; k < 4; k = k + 1) open_row[k] <= 11'd0;
            {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_NOP;
        end else begin
            {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_NOP;
            dq_oe     <= 1'b0;
            p0_done   <= 1'b0;
            p1_done   <= 1'b0;
            p2_done   <= 1'b0;
            p0_rvalid <= 1'b0;
            p1_rvalid <= 1'b0;
            p2_rvalid <= 1'b0;

            if (refresh_timer >= REFRESH_INTERVAL[15:0]) begin
                refresh_timer   <= 16'd0;
                refresh_pending <= 1'b1;
            end else begin
                refresh_timer <= refresh_timer + 1'b1;
            end

            if (delay != 16'd0) begin
                delay <= delay - 1'b1;
            end else begin
                case (state)
                //--------------------------------------------------
                S_INIT_WAIT: begin
                    sdram_dqm <= 4'b1111;
                    state     <= S_INIT_PRE;
                end
                S_INIT_PRE: begin
                    {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
                    sdram_a <= 11'b100_0000_0000;
                    delay   <= T_RP - 1;
                    state   <= S_INIT_REF;
                end
                S_INIT_REF: begin
                    {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_REFRESH;
                    delay <= T_RC - 1;
                    if (init_refresh == 4'd7) state <= S_INIT_MODE;
                    else init_refresh <= init_refresh + 1'b1;
                end
                S_INIT_MODE: begin
                    {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_LOADMODE;
                    sdram_a   <= MODE_REG;
                    sdram_ba  <= 2'b00;
                    delay     <= T_MRD - 1;
                    state     <= S_IDLE;
                    done_flag <= 1'b1;
                end

                //--------------------------------------------------
                S_IDLE: begin
                    sdram_dqm <= 4'b0000;
                    if (refresh_pending) begin
                        // every bank must be idle before a refresh
                        {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
                        sdram_a  <= 11'b100_0000_0000;    // all banks
                        row_open <= 4'b0000;
                        delay    <= T_RP - 1;
                        state    <= S_REFRESH;
                    end else if (any_req) begin
                        sel         <= nxt_sel;
                        latched_sel <= nxt_sel;
                        state       <= S_PRE;
                    end
                end

                // Close the bank's row only if it holds the wrong one.
                S_PRE: begin
                    if (bank_hit) begin
                        state <= c_we ? S_WRITE : S_READ;
                    end else if (bank_busy) begin
                        {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
                        sdram_a          <= 11'd0;         // A10 = 0: this bank
                        sdram_ba         <= req_bank;
                        row_open[req_bank] <= 1'b0;
                        delay            <= T_RP - 1;
                        state            <= S_ACT;
                    end else begin
                        state <= S_ACT;
                    end
                end

                S_ACT: begin
                    {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_ACTIVE;
                    sdram_a            <= req_row;
                    sdram_ba           <= req_bank;
                    open_row[req_bank] <= req_row;
                    row_open[req_bank] <= 1'b1;
                    delay              <= T_RCD - 1;
                    state              <= c_we ? S_WRITE : S_READ;
                end

                // A10 low: keep the row open for the next access.
                S_READ: begin
                    {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_READ;
                    sdram_a   <= {3'b000, req_col};
                    sdram_ba  <= req_bank;
                    sdram_dqm <= 4'b0000;
                    beat      <= 3'd0;
                    delay     <= CAS - 1;
                    state     <= S_RDATA;
                end
                S_RDATA: begin
                    rdata     <= sdram_dq;
                    p0_rvalid <= (latched_sel == 2'd0);
                    p1_rvalid <= (latched_sel == 2'd1);
                    p2_rvalid <= (latched_sel == 2'd2);
                    if (beat == BURST - 1) state <= S_DONE;
                    else                   beat  <= beat + 1'b1;
                end

                S_WRITE: begin
                    {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_WRITE;
                    sdram_a   <= {3'b000, req_col};
                    sdram_ba  <= req_bank;
                    dq_out    <= c_wdata;
                    dq_oe     <= 1'b1;
                    sdram_dqm <= ~c_wmask;
                    delay     <= T_WR - 1;
                    state     <= S_WDONE;
                end
                S_WDONE: state <= S_DONE;

                S_DONE: begin
                    p0_done <= (latched_sel == 2'd0);
                    p1_done <= (latched_sel == 2'd1);
                    p2_done <= (latched_sel == 2'd2);
                    state   <= S_GAP;
                end

                // Masters hold req until they see done, so returning straight
                // to S_IDLE would re-latch the finished request and run it again.
                S_GAP: state <= S_IDLE;

                //--------------------------------------------------
                S_REFRESH: begin
                    {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_REFRESH;
                    refresh_pending <= 1'b0;
                    delay <= T_RC - 1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
