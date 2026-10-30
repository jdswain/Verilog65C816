//============================================================================
// external_bus.v -- bridge from the CPU bus to the carrier's peripherals
//
// One bus style: Intel RD#/WR# strobes, as every planned device uses (the
// 82077AA, both halves of the Z85C80, the W5100S). docs/Hardware.md has the
// reasoning; the 6502 style and its PHI0 clock are gone.
//
// TIMING. The bridge counts in a bus clock T of T_CLKS system clocks, at
// least 119 ns (8.4 MHz), and an edge gap H of H_CLKS clocks, at least 40 ns;
// soc.v works both out from the system clock. No clock goes to the cards; T
// is only the unit. At 25.2 MHz T is 3 clocks and H is 1. Counting system
// clocks from the one that starts a cycle:
//
//    0     address (ext_a), select code and, for a write, data go out
//    H     select enable falls: the decoder's inputs have settled first
//    T     RD# or WR# falls (T2): one T of address and select setup
//    3T    the strobe rises (end of T3), and read data is taken from the
//          bus as it was in the strobe's last clock: a 2T (238 ns) strobe
//    3T+H  the enable rises: 40 ns of hold
//    3T+H+1  data stops being driven, and the CPU gets ack
//
// A cycle takes about 480 ns, against 1-2 us with the old 1 MHz PHI0.
//
// SELECTS. The four select pins are a three-bit code and an active-low
// enable, for a 74HCT138 on the carrier: eight slots of 16 registers,
// addr[6:4] the code and addr[3:0] A3-A0, mirrored every 128 bytes across
// the window. The enable is low only while the code is steady, so the
// decoder's outputs never glitch. That matters for the /DACK slots: on the
// 53C80 a glitch on /DACK clears DRQ.
//
// SCC RECOVERY. The Z85C30 needs 3.5 PCLK periods (475 ns at 7.3728 MHz)
// from one access's falling strobe to the next's. Back-to-back cycles here
// are only just further apart (13 clocks, 516 ns, at 25.2 MHz), and a DMA
// cycle could come sooner. A cycle to slot 2, the SCC, waits until its
// strobe will fall at least 5T (595 ns or more) after the last one to slot
// 2 fell. No other slot waits.
//
// RESET. While RES# is asserted -- the SoC in reset, or the card_reset bit
// -- RD# and WR# are both held low. Only the SCC takes that as a reset; the
// others are not selected and ignore it. The SCC has no reset pin, so this
// is its hardware reset. CPU accesses meanwhile end at once, read $FF and
// touch nothing: a cycle would end the SCC's reset.
//
// DMA. dma.v asks for cycles on a second port: a cycle to a /DACK slot,
// with no address (ext_a is 0; the chips ignore it during /DACK), RD# to
// read from the device and WR# to write to it, and TC high from the start
// of the cycle until the enable rises, 40 ns after the strobe, when it is
// the transfer's last byte: the chips see TC with /DACK across the strobe's
// rising edge.
// When both are waiting the DMA cycle goes first, so the CPU waits at most
// one. The DMA port's data comes back in `rdata` too, flagged by `dma_ack`.
//
// The CPU is stalled through `ack` for the whole cycle.
//============================================================================
`default_nettype none

module external_bus #(
    parameter integer T_CLKS = 3,          // system clocks in a bus clock T
    parameter integer H_CLKS = 1           // system clocks in 40 ns
) (
    input  wire       clk,
    input  wire       rst_n,

    // CPU side
    input  wire [10:0] addr,             // offset within the external window
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,
    input  wire        req,              // held for the access
    input  wire        we,
    output reg         ack,              // one cycle when the access completes

    // DMA side (dma.v)
    input  wire        dma_req,          // held for the cycle
    input  wire        dma_we,           // 1 = WR#, memory to device
    input  wire [2:0]  dma_slot,         // the /DACK slot
    input  wire        dma_tc,           // assert TC during this cycle
    input  wire [7:0]  dma_wdata,
    output reg         dma_ack,          // one cycle; rdata holds a read

    // control register side
    input  wire        card_reset,       // assert RES to the cards
    output wire        irq,              // card IRQ, active high to the CPU

    // external pins
    output reg  [3:0]  ext_a,
    input  wire [7:0]  ext_d_in,
    output reg  [7:0]  ext_d_out,
    output reg         ext_d_oe,         // 1 = we drive the data bus
    output reg  [2:0]  ext_sel,          // select code, to the '138
    output reg         ext_sel_en_n,     // select enable, active low
    output reg         ext_rd_n,
    output reg         ext_wr_n,
    output reg         ext_tc,           // terminal count, active high
    output wire        ext_res_n,
    input  wire        ext_irq_n
);
    localparam integer CW = 5;
    localparam [CW-1:0] C_EN     = H_CLKS;                  // enable falls
    localparam [CW-1:0] C_STROBE = T_CLKS;                  // strobe falls
    localparam [CW-1:0] C_RISE   = 3 * T_CLKS;              // strobe rises
    localparam [CW-1:0] C_HOLD   = 3 * T_CLKS + H_CLKS;     // enable rises
    localparam [CW-1:0] C_END    = 3 * T_CLKS + H_CLKS + 1; // data released, ack

    // From one SCC strobe's fall to the next's: 5T. The next cycle's strobe
    // falls C_STROBE clocks after it starts, so it may start this much
    // after the last fall.
    localparam [CW-1:0] SCC_GAP  = 5 * T_CLKS - T_CLKS;
    localparam [2:0]    SCC_SLOT = 3'd2;

    assign ext_res_n = rst_n & ~card_reset;

    // IRQ arrives asynchronously from a card, so synchronise it before it
    // reaches the CPU. Cards pull the line low, so low means asserted.
    reg [1:0] irq_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) irq_sync <= 2'b11;
        else        irq_sync <= {irq_sync[0], ext_irq_n};
    end
    assign irq = ~irq_sync[1];

    wire [2:0] slot = addr[6:4];

    //------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_CYCLE = 2'd1, S_GAP = 2'd2;

    reg [1:0]    state;
    reg [CW-1:0] cnt;                    // system clocks into the cycle
    reg [CW-1:0] scc_wait;               // clocks until slot 2 may start
    reg          cyc_we;
    reg          cyc_dma;                // this cycle is the DMA port's

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            cnt          <= {CW{1'b0}};
            scc_wait     <= {CW{1'b0}};
            cyc_we       <= 1'b0;
            cyc_dma      <= 1'b0;
            ack          <= 1'b0;
            dma_ack      <= 1'b0;
            ext_tc       <= 1'b0;
            ext_a        <= 4'd0;
            ext_sel      <= 3'd0;
            ext_sel_en_n <= 1'b1;
            ext_d_out    <= 8'd0;
            ext_d_oe     <= 1'b0;
            ext_rd_n     <= 1'b0;       // RES# is asserted: both strobes low
            ext_wr_n     <= 1'b0;
            rdata        <= 8'hFF;
        end else begin
            ack     <= 1'b0;
            dma_ack <= 1'b0;
            if (scc_wait != {CW{1'b0}}) scc_wait <= scc_wait - 1'b1;

            case (state)
            S_IDLE: begin
                ext_sel_en_n <= 1'b1;
                ext_d_oe     <= 1'b0;
                ext_rd_n     <= ~card_reset;
                ext_wr_n     <= ~card_reset;
                if ((req || dma_req) && card_reset) begin
                    rdata   <= 8'hFF;    // the cards are in reset
                    ack     <= req;
                    dma_ack <= dma_req;
                    state   <= S_GAP;
                end else if (dma_req) begin
                    ext_a     <= 4'd0;
                    ext_sel   <= dma_slot;
                    ext_d_out <= dma_wdata;
                    ext_d_oe  <= dma_we;
                    ext_tc    <= dma_tc;
                    cyc_we    <= dma_we;
                    cyc_dma   <= 1'b1;
                    cnt       <= {CW{1'b0}};
                    state     <= S_CYCLE;
                end else if (req && !(slot == SCC_SLOT && scc_wait != {CW{1'b0}})) begin
                    ext_a     <= addr[3:0];
                    ext_sel   <= slot;
                    ext_d_out <= wdata;
                    ext_d_oe  <= we;
                    cyc_we    <= we;
                    cyc_dma   <= 1'b0;
                    cnt       <= {CW{1'b0}};
                    state     <= S_CYCLE;
                end
            end

            S_CYCLE: begin
                cnt <= cnt + 1'b1;
                // cnt is the clock just finished, so each action below lands
                // on clock cnt + 1 of the cycle.
                case (cnt + 1'b1)
                C_EN:     ext_sel_en_n <= 1'b0;
                C_STROBE: begin
                    if (cyc_we) ext_wr_n <= 1'b0;
                    else        ext_rd_n <= 1'b0;
                    if (ext_sel == SCC_SLOT) scc_wait <= SCC_GAP;
                end
                C_RISE: begin
                    rdata    <= ext_d_in;
                    ext_rd_n <= 1'b1;
                    ext_wr_n <= 1'b1;
                end
                C_HOLD: begin
                    ext_sel_en_n <= 1'b1;
                    ext_tc       <= 1'b0;   // held past the strobe, with /DACK
                end
                C_END: begin
                    ext_d_oe <= 1'b0;
                    ack      <= ~cyc_dma;
                    dma_ack  <= cyc_dma;
                    state    <= S_GAP;
                end
                default: ;
                endcase
            end

            // One cycle for the CPU to see ack and move on before we look at
            // `req` again, or we would restart the finished access.
            S_GAP: state <= S_IDLE;

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
