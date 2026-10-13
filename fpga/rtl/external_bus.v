//============================================================================
// external_bus.v -- bridge from the CPU bus to an external peripheral card
//
// First target is a WD1773 floppy card wired much like an Apple II slot, with
// the option of an Intel-style card (82077AA) or a real Z8530 later. The style
// is a BUILD-TIME parameter: both use the same two strobe pins, so swapping
// cards means re-synthesising rather than rewiring.
//
//   STYLE_6502 (0): ext_phi0 is a free-running clock, ext_rw is high for read.
//                   The card sees a classic 6502 cycle -- address and R/W set
//                   up while PHI0 is low, data transferred while it is high.
//
//   STYLE_INTEL (1): ext_phi0 becomes RD# and ext_rw becomes WR#, each pulsed
//                   low for the access with address set up beforehand.
//
// Four active-low selects are decoded here rather than externally: that costs
// one more pin than exposing extra address lines and a 74-series decoder, and
// removes a part from the board.
//
// PHI0 is fixed at 1 MHz. The CPU is stalled through `ack` for the whole
// external cycle -- about 1-2 us -- which is what makes slow cards safe.
//============================================================================
`default_nettype none

module external_bus #(
    parameter integer CLK_HZ  = 25_200_000,
    parameter integer PHI0_HZ = 1_000_000,
    parameter integer STYLE   = 0        // 0 = 6502, 1 = Intel RD#/WR#
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

    // control register side
    input  wire        card_reset,       // assert RES to the cards
    output wire        irq,              // card IRQ, active high to the CPU

    // external pins
    output reg  [3:0]  ext_a,
    input  wire [7:0]  ext_d_in,
    output reg  [7:0]  ext_d_out,
    output reg         ext_d_oe,         // 1 = we drive the data bus
    output reg  [3:0]  ext_sel_n,
    output reg         ext_rw,           // 6502: 1 = read.  Intel: WR#
    output reg         ext_phi0,         // 6502: clock.     Intel: RD#
    output wire        ext_res_n,
    input  wire        ext_irq_n
);
    localparam integer HALF = (CLK_HZ / PHI0_HZ) / 2;   // half a PHI0 period
    localparam integer CW   = 8;

    localparam STYLE_6502  = 0;
    localparam STYLE_INTEL = 1;

    assign ext_res_n = rst_n & ~card_reset;

    // IRQ arrives asynchronously from a card, so synchronise it before it
    // reaches the CPU. Cards pull the line low, so low means asserted.
    reg [1:0] irq_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) irq_sync <= 2'b11;
        else        irq_sync <= {irq_sync[0], ext_irq_n};
    end
    assign irq = ~irq_sync[1];

    // Within the 2 KB window: addr[5:4] picks the card, addr[3:0] is A3-A0.
    wire [1:0] card = addr[5:4];

    //------------------------------------------------------------------
    // Free-running PHI0 (6502 style only)
    //------------------------------------------------------------------
    reg [CW-1:0] phi_cnt;
    reg          phi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phi_cnt <= {CW{1'b0}};
            phi     <= 1'b0;
        end else if (phi_cnt >= HALF[CW-1:0] - 1) begin
            phi_cnt <= {CW{1'b0}};
            phi     <= ~phi;
        end else begin
            phi_cnt <= phi_cnt + 1'b1;
        end
    end

    reg phi_d;
    always @(posedge clk) phi_d <= phi;
    wire phi_fall = phi_d & ~phi;
    wire phi_rise = ~phi_d & phi;

    //------------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_SYNC = 3'd1, S_ACTIVE = 3'd2,
                     S_SAMPLE = 3'd3, S_END = 3'd4, S_GAP = 3'd5;

    reg [2:0]    state;
    reg [CW-1:0] timer;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            ack       <= 1'b0;
            ext_a     <= 4'd0;
            ext_sel_n <= 4'b1111;
            ext_d_out <= 8'd0;
            ext_d_oe  <= 1'b0;
            ext_rw    <= (STYLE == STYLE_6502) ? 1'b1 : 1'b1;   // idle inactive
            ext_phi0  <= (STYLE == STYLE_6502) ? 1'b0 : 1'b1;
            rdata     <= 8'hFF;
            timer     <= {CW{1'b0}};
        end else begin
            ack <= 1'b0;

            // In 6502 mode the card needs a clock whether or not we are
            // accessing it, so PHI0 runs continuously.
            if (STYLE == STYLE_6502) ext_phi0 <= phi;

            case (state)
            S_IDLE: begin
                ext_sel_n <= 4'b1111;
                ext_d_oe  <= 1'b0;
                if (req) begin
                    ext_a     <= addr[3:0];
                    ext_d_out <= wdata;
                    if (STYLE == STYLE_6502) begin
                        ext_rw <= ~we;                  // high = read
                        state  <= S_SYNC;               // align to the clock
                    end else begin
                        // Intel: address, select and (for a write) data go out
                        // first; the strobe follows after a setup delay, which
                        // is the tAR/tDW the parts ask for.
                        ext_sel_n[card] <= 1'b0;
                        ext_d_oe        <= we;
                        timer <= HALF[CW-1:0];
                        state <= S_ACTIVE;
                    end
                end
            end

            // 6502: start the cycle on a falling edge of PHI0, so address and
            // R/W are set up during the low phase as a 6502 would present them.
            S_SYNC: if (phi_fall) begin
                ext_sel_n[card] <= 1'b0;
                ext_d_oe        <= we;
                state           <= S_ACTIVE;
            end

            S_ACTIVE: begin
                if (STYLE == STYLE_6502) begin
                    // Data is valid during the high phase; sample at its end.
                    if (phi_fall) state <= S_SAMPLE;
                end else begin
                    if (timer != {CW{1'b0}}) begin
                        timer <= timer - 1'b1;
                    end else begin
                        // Address and select are set up: assert the strobe.
                        if (we) ext_rw   <= 1'b0;       // WR#
                        else    ext_phi0 <= 1'b0;       // RD#
                        timer <= HALF[CW-1:0];
                        state <= S_SAMPLE;
                    end
                end
            end

            S_SAMPLE: begin
                if (STYLE == STYLE_6502) begin
                    rdata <= ext_d_in;
                    state <= S_END;
                end else if (timer != {CW{1'b0}}) begin
                    timer <= timer - 1'b1;
                end else begin
                    rdata    <= ext_d_in;               // before the strobe rises
                    ext_rw   <= 1'b1;
                    ext_phi0 <= 1'b1;
                    state    <= S_END;
                end
            end

            S_END: begin
                ext_sel_n <= 4'b1111;
                ext_d_oe  <= 1'b0;
                ack       <= 1'b1;
                state     <= S_GAP;
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
