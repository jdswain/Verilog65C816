//============================================================================
// power.v -- soft power and the power LED, $0480
//
// The carrier (65-16 Power sheet) switches the ATX supply with a latch on
// its standby rail. The ADB power key, or a case button, sets the latch;
// the FPGA clears it by toggling its LED pin fast: a capacitor and diode pump
// on the carrier turn a burst of about 10 kHz into the latch's clear, and
// nothing slower gets through. So the LED pin is two things at once:
//
//   * the power LED, steady while running (or a slow blink on request);
//   * the off line: OFF_MS of toggling at about 10 kHz turns the supply off.
//
// Anything that toggles the pin fast for long enough turns the machine off,
// so the LED is never PWMed, and its output changes at most once every
// LED_MS however fast software writes CONTROL: only the off burst can reach
// the pump.
//
// The power key reaches the FPGA through a Schottky on FPGA pin 53 (the DDC
// clock, pulled up on the Tang Nano): low while the key is down. Without the
// carrier, or with the diode unfitted, it reads up.
//
// A press is debounced, latched in PRESSED and can interrupt (ISTAT bit 5,
// with IE). Holding the key for HOLD_MS turns the supply off in hardware,
// whatever the CPU is doing. Both wait until the key has been seen up since
// reset, so the press that switched the supply on -- often still held while
// the FPGA configures -- neither reports nor counts towards the hold.
//
// Registers (reg_addr[1:0], mirrored through the 64-byte slot):
//   +0  STATUS   read: bit 0 KEY, the key is down (debounced; a key held
//                since reset shows once it has been let go); bit 1 PRESSED,
//                set when the key goes down, write 1 to clear; bit 7 OFF,
//                the off burst is running
//   +1  CONTROL  bit 0 LED, 1 = lit (1 at reset: the power LED);
//                bit 1 BLINK, the LED flashes at about 1 Hz instead;
//                bit 2 IE, PRESSED interrupts (0 at reset)
//   +2  OFF      write $A5: turn the supply off (the OFF_MS burst). Other
//                values are ignored. Reads 0.
//   +3           reads 0
// After the burst the LED follows CONTROL again: if the supply is still on
// (soft power not fitted, or JP4's shunt in) the machine simply carries on.
//
// `led` is active high here; the top level inverts it for the board.
//============================================================================
`default_nettype none

module power #(
    parameter integer SYS_HZ      = 40_500_000,
    parameter integer MS_CLKS     = SYS_HZ / 1000,     // clocks per millisecond
    parameter integer OFF_HALF    = SYS_HZ / 20_000,   // half a period at 10 kHz
    parameter integer DEBOUNCE_MS = 10,
    parameter integer HOLD_MS     = 4000,
    parameter integer OFF_MS      = 50,
    parameter integer LED_MS      = 16,             // powers of two: they become bit tests
    parameter integer BLINK_MS    = 512
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [1:0] reg_addr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata,            // combinational from reg_addr
    input  wire       cs,               // one-cycle strobe
    input  wire       we,

    input  wire       key_n,            // the power key, low while down (async)
    output wire       led,              // the LED pin, active high
    output wire       irq               // PRESSED & IE
);
    localparam integer MSW  = $clog2(MS_CLKS + 1);
    localparam integer OFFW = $clog2(OFF_HALF + 1);
    localparam integer HW   = $clog2(HOLD_MS + 1);

    wire wr = cs & we;

    // A millisecond tick for the debounce, the hold, the burst and the LED
    reg [MSW-1:0] ms_div;
    wire ms = (ms_div == MS_CLKS - 1);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) ms_div <= {MSW{1'b0}};
        else        ms_div <= ms ? {MSW{1'b0}} : ms_div + 1'b1;

    //------------------------------------------------------------------
    // The key: synchronized, then debounced over DEBOUNCE_MS
    //------------------------------------------------------------------
    reg [1:0] key_s;
    reg       key;                      // debounced, 1 = down; starts down, so
                                        // it arms only once seen up for DEBOUNCE_MS
    reg [7:0] deb;
    reg       armed;                    // the key has been seen up since reset
    reg       pressed;
    reg [HW-1:0] hold;
    wire      key_raw = ~key_s[1];
    wire      key_dn  = (key_raw != key) & ms & (deb == DEBOUNCE_MS - 1) & key_raw;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) key_s <= 2'b11;
        else        key_s <= {key_s[0], key_n};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key <= 1'b1; deb <= 8'd0;
        end else if (key_raw == key)
            deb <= 8'd0;
        else if (ms) begin
            if (deb == DEBOUNCE_MS - 1) begin key <= key_raw; deb <= 8'd0; end
            else                        deb <= deb + 1'b1;
        end
    end

    //------------------------------------------------------------------
    // CONTROL, PRESSED, the hold and the off burst
    //------------------------------------------------------------------
    reg        led_on, blink, ie;
    reg        off_run;
    reg [7:0]  off_ms;
    wire       hold_off = armed & key & ms & (hold == HOLD_MS - 1);
    wire       off_go   = (wr & (reg_addr == 2'd2) & (wdata == 8'hA5)) | hold_off;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            led_on <= 1'b1; blink <= 1'b0; ie <= 1'b0;
            armed <= 1'b0; pressed <= 1'b0; hold <= {HW{1'b0}};
            off_run <= 1'b0; off_ms <= 8'd0;
        end else begin
            if (wr & (reg_addr == 2'd1)) begin
                led_on <= wdata[0]; blink <= wdata[1]; ie <= wdata[2];
            end

            if (~key) armed <= 1'b1;
            else if (hold_off) armed <= 1'b0;   // once per press

            if (armed & key_dn) pressed <= 1'b1;
            else if (wr & (reg_addr == 2'd0) & wdata[1]) pressed <= 1'b0;

            if (~(armed & key)) hold <= {HW{1'b0}};
            else if (ms & ~hold_off) hold <= hold + 1'b1;

            if (off_go) begin
                off_run <= 1'b1; off_ms <= OFF_MS;
            end else if (off_run & ms) begin
                if (off_ms == 8'd1) off_run <= 1'b0;
                off_ms <= off_ms - 1'b1;
            end
        end
    end

    //------------------------------------------------------------------
    // The pin: the burst, else CONTROL at most once every LED_MS
    //------------------------------------------------------------------
    reg [OFFW-1:0] half;
    reg            tog;
    reg [9:0]      slow;                // ms since reset, for LED_MS and the blink
    reg            led_q;               // CONTROL as the pin shows it
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half <= {OFFW{1'b0}}; tog <= 1'b0;
        end else if (!off_run) begin
            half <= {OFFW{1'b0}}; tog <= ~led_q;
        end else if (half == OFF_HALF - 1) begin
            half <= {OFFW{1'b0}}; tog <= ~tog;
        end else
            half <= half + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slow <= 10'd0; led_q <= 1'b1;
        end else if (ms) begin
            slow <= slow + 1'b1;
            if (slow % LED_MS == 0)
                led_q <= led_on & ~(blink & ((slow / BLINK_MS) % 2 == 1));
        end
    end

    assign led = off_run ? tog : led_q;
    assign irq = pressed & ie;

    always @* begin
        case (reg_addr)
            2'd0:    rdata = {off_run, 5'd0, pressed, key & armed};
            2'd1:    rdata = {5'd0, ie, blink, led_on};
            default: rdata = 8'd0;
        endcase
    end
endmodule

`default_nettype wire
