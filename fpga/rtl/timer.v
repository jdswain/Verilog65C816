//============================================================================
// timer.v -- the system tick timer, $0450
//
// A 16-bit down-counter that raises a pending flag every RELOAD counts, for
// the operating system's clock tick, and a 32-bit count of those ticks that
// keeps going while the IRQ is masked or not serviced.
//
// It counts at 25.2 MHz whatever the system clock: a count is TNUM/TDEN of
// a system clock, spread evenly (a phase accumulator), so the unit and the
// software that sets RELOAD stay the same when the system clock changes.
// TNUM = TDEN counts every clock.
//
// Registers (reg_addr[3:0], mirrored):
//   +0, +1  RELOAD   the period in counts (25.2 MHz), low first; 0 means
//                    65536. 63000 is 2.5 ms. A write takes effect at
//                    the next tick, or when the timer is enabled.
//   +2      CTRL     bit 0 EN. Setting it (0 -> 1) starts a period of RELOAD
//                    counts; clearing it stops the counter, the tick count
//                    stops with it.
//   +3      STATUS   bit 0 PENDING, set at each tick; write 1 to clear. It
//                    is the timer's interrupt (the IRQ goes through $0440).
//   +4, +5  NOW      the down-counter, as latched by a read of +8: counts
//                    left until the next tick (RELOAD-1 just after a tick).
//   +8..+B  TICKS    ticks since reset, low first. Reading +8 latches all
//                    four bytes and NOW, so read +8 first, then +9..+B and
//                    +4/+5, for a consistent snapshot.
// Unlisted offsets read 0.
//============================================================================
module timer #(
    parameter integer TNUM = 1,          // a count is TNUM/TDEN of a clock
    parameter integer TDEN = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [3:0]  reg_addr,
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,            // combinational from reg_addr
    input  wire        cs,               // one-cycle strobe
    input  wire        we,
    output reg         pending
);
    reg [15:0] reload;
    reg        en;
    reg [15:0] cnt;                      // counts left in this period, minus 1
    reg [15:0] acc;                      // the prescaler's phase
    reg [31:0] ticks;
    reg [31:0] ticks_l;
    reg [15:0] now_l;

    wire wr   = cs & we;

    // A count this clock: the phase accumulator wraps past TDEN.
    wire [16:0] acc_n = {1'b0, acc} + TNUM;
    wire        adv   = (TNUM == TDEN) | (acc_n >= TDEN);
    wire tick = en & adv & (cnt == 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reload  <= 16'd0;
            en      <= 1'b0;
            cnt     <= 16'd0;
            acc     <= 16'd0;
            ticks   <= 32'd0;
            ticks_l <= 32'd0;
            now_l   <= 16'd0;
            pending <= 1'b0;
        end else begin
            if (en) acc <= adv ? acc_n - TDEN : acc_n[15:0];
            if (tick) begin
                cnt   <= reload - 1'b1;      // 0 wraps to 65535: 65536 counts
                ticks <= ticks + 1'b1;
            end else if (en & adv)
                cnt   <= cnt - 1'b1;

            if (tick) pending <= 1'b1;
            else if (wr & (reg_addr == 4'd3) & wdata[0]) pending <= 1'b0;

            if (wr) case (reg_addr)
                4'd0: reload[7:0]  <= wdata;
                4'd1: reload[15:8] <= wdata;
                4'd2: begin
                    en <= wdata[0];
                    if (wdata[0] & ~en) begin cnt <= reload - 1'b1; acc <= 16'd0; end
                end
                default: ;
            endcase

            if (cs & ~we & (reg_addr == 4'd8)) begin
                ticks_l <= ticks;
                now_l   <= cnt;
            end
        end
    end

    // A read of +8 returns the live low byte, the one it latches.
    always @* begin
        case (reg_addr)
            4'd0:    rdata = reload[7:0];
            4'd1:    rdata = reload[15:8];
            4'd2:    rdata = {7'd0, en};
            4'd3:    rdata = {7'd0, pending};
            4'd4:    rdata = now_l[7:0];
            4'd5:    rdata = now_l[15:8];
            4'd8:    rdata = ticks[7:0];
            4'd9:    rdata = ticks_l[15:8];
            4'd10:   rdata = ticks_l[23:16];
            4'd11:   rdata = ticks_l[31:24];
            default: rdata = 8'd0;
        endcase
    end
endmodule
