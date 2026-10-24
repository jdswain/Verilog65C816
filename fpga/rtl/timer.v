//============================================================================
// timer.v -- the system tick timer, $0450
//
// A 16-bit down-counter on the system clock that raises a pending flag every
// RELOAD clocks, for the operating system's clock tick, and a 32-bit count
// of those ticks that keeps going while the IRQ is masked or not serviced.
//
// Registers (reg_addr[3:0], mirrored):
//   +0, +1  RELOAD   the period in system clocks, low first; 0 means 65536.
//                    63000 is 2.5 ms at 25.2 MHz. A write takes effect at
//                    the next tick, or when the timer is enabled.
//   +2      CTRL     bit 0 EN. Setting it (0 -> 1) starts a period of RELOAD
//                    clocks; clearing it stops the counter, the tick count
//                    stops with it.
//   +3      STATUS   bit 0 PENDING, set at each tick; write 1 to clear. It
//                    is the timer's interrupt (the IRQ goes through $0440).
//   +4, +5  NOW      the down-counter, as latched by a read of +8: clocks
//                    left until the next tick (RELOAD-1 just after a tick).
//   +8..+B  TICKS    ticks since reset, low first. Reading +8 latches all
//                    four bytes and NOW, so read +8 first, then +9..+B and
//                    +4/+5, for a consistent snapshot.
// Unlisted offsets read 0.
//============================================================================
module timer (
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
    reg [15:0] cnt;                      // clocks left in this period, minus 1
    reg [31:0] ticks;
    reg [31:0] ticks_l;
    reg [15:0] now_l;

    wire wr   = cs & we;
    wire tick = en & (cnt == 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reload  <= 16'd0;
            en      <= 1'b0;
            cnt     <= 16'd0;
            ticks   <= 32'd0;
            ticks_l <= 32'd0;
            now_l   <= 16'd0;
            pending <= 1'b0;
        end else begin
            if (tick) begin
                cnt   <= reload - 1'b1;      // 0 wraps to 65535: 65536 clocks
                ticks <= ticks + 1'b1;
            end else if (en)
                cnt   <= cnt - 1'b1;

            if (tick) pending <= 1'b1;
            else if (wr & (reg_addr == 4'd3) & wdata[0]) pending <= 1'b0;

            if (wr) case (reg_addr)
                4'd0: reload[7:0]  <= wdata;
                4'd1: reload[15:8] <= wdata;
                4'd2: begin
                    en <= wdata[0];
                    if (wdata[0] & ~en) cnt <= reload - 1'b1;
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
