// tb_power.v -- power.v: the key, PRESSED and its interrupt, the hold, the off
// burst, the LED's rate limit and blink. Time is scaled down: a "millisecond"
// is 10 clocks, the off toggle's half period 2 clocks.
//
//   iverilog -g2005 -o /tmp/tb_power sim/tb_power.v rtl/power.v && vvp /tmp/tb_power
`timescale 1ns/1ps
`default_nettype none

module tb_power;
    localparam integer MS = 10, HALF = 2, DEB = 3, HOLD = 40, OFF = 5, LEDMS = 4, BLINK = 8;

    reg        clk = 1'b0, rst_n = 1'b0;
    reg  [1:0] reg_addr = 2'd0;
    reg  [7:0] wdata = 8'd0;
    reg        cs = 1'b0, we = 1'b0;
    reg        key_n = 1'b1;
    wire [7:0] rdata;
    wire       led, irq;

    power #(.SYS_HZ(10_000), .MS_CLKS(MS), .OFF_HALF(HALF), .DEBOUNCE_MS(DEB),
            .HOLD_MS(HOLD), .OFF_MS(OFF), .LED_MS(LEDMS), .BLINK_MS(BLINK)) dut (
        .clk(clk), .rst_n(rst_n), .reg_addr(reg_addr), .wdata(wdata), .rdata(rdata),
        .cs(cs), .we(we), .key_n(key_n), .led(led), .irq(irq));

    always #5 clk = ~clk;

    integer errors = 0;
    task check(input cond, input [8*64-1:0] what);
        if (!cond) begin errors = errors + 1; $display("FAIL %0s at %0t", what, $time); end
    endtask

    task wr(input [1:0] a, input [7:0] d);
        begin
            @(negedge clk); reg_addr = a; wdata = d; cs = 1'b1; we = 1'b1;
            @(negedge clk); cs = 1'b0; we = 1'b0;
        end
    endtask

    task rd(input [1:0] a, output [7:0] d);
        begin @(negedge clk); reg_addr = a; #1 d = rdata; end
    endtask

    task ms(input integer n); repeat (n * MS) @(posedge clk); endtask

    // Edges on the LED pin, counted from a mark
    integer edges = 0;
    reg led_d = 1'b1;
    always @(posedge clk) begin
        if (led !== led_d) edges = edges + 1;
        led_d <= led;
    end

    reg [7:0] d;
    integer e0, i;
    initial begin
        repeat (3) @(posedge clk);
        // ---- reset state: the power LED on, nothing pressed
        key_n = 1'b0;                       // the key that switched us on, still held
        rst_n = 1'b1;
        ms(1);
        check(led === 1'b1, "LED lit after reset");
        rd(2'd1, d); check(d == 8'h01, "CONTROL = $01 after reset");

        // ---- held through reset: no KEY, no PRESSED and no hold until let go
        ms(DEB + 2);
        rd(2'd0, d); check(d == 8'h00, "a key held from reset shows nothing");
        e0 = edges;
        ms(HOLD + 10);
        check(edges == e0, "no burst for a key held since reset");
        key_n = 1'b1; ms(DEB + 2);
        rd(2'd0, d); check(d == 8'h00, "KEY up");

        // ---- a bounce shorter than the debounce is ignored
        key_n = 1'b0; ms(1); key_n = 1'b1; ms(DEB + 2);
        rd(2'd0, d); check(d == 8'h00, "bounce ignored");

        // ---- a press: PRESSED, the interrupt with IE, write 1 to clear
        key_n = 1'b0; ms(DEB + 2);
        rd(2'd0, d); check(d == 8'h03, "KEY and PRESSED");
        check(irq === 1'b0, "no IRQ with IE clear");
        wr(2'd1, 8'h05);                    // LED on, IE
        check(irq === 1'b1, "IRQ with IE set");
        wr(2'd0, 8'h02);
        rd(2'd0, d); check(d == 8'h01, "PRESSED cleared, KEY still down");
        check(irq === 1'b0, "IRQ gone");
        key_n = 1'b1; ms(DEB + 2);

        // ---- a hold of HOLD ms: the burst, once
        key_n = 1'b0;
        ms(DEB + HOLD - 2);
        rd(2'd0, d); check(d[7] == 1'b0, "no burst before HOLD");
        e0 = edges;
        ms(4);
        rd(2'd0, d); check(d[7] == 1'b1, "burst running after HOLD");
        ms(OFF + 1);
        rd(2'd0, d); check(d[7] == 1'b0, "burst over");
        // OFF ms of toggling every HALF clocks, give or take a millisecond
        check(edges - e0 >= (OFF - 1) * MS / HALF && edges - e0 <= (OFF + 1) * MS / HALF + 2, "burst length");
        check(led === 1'b1, "LED back to CONTROL after the burst");
        e0 = edges;
        ms(HOLD + 10);
        check(edges == e0, "one burst per hold");
        key_n = 1'b1; ms(DEB + 2);
        wr(2'd0, 8'h02);

        // ---- OFF: $A5 starts the burst, anything else does not
        e0 = edges;
        wr(2'd2, 8'hA4); ms(2);
        check(edges == e0, "OFF ignores $A4");
        wr(2'd2, 8'hA5); ms(1);
        rd(2'd0, d); check(d[7] == 1'b1, "OFF $A5 starts the burst");
        ms(OFF + 1);
        rd(2'd2, d); check(d == 8'h00, "OFF reads 0");

        // ---- software flapping CONTROL cannot toggle the pin fast
        e0 = edges;
        for (i = 0; i < 200; i = i + 1) wr(2'd1, {7'd0, i[0]});
        check(edges - e0 <= (400 / (LEDMS * MS)) + 2, "LED rate limited");
        wr(2'd1, 8'h01); ms(LEDMS + 1);
        check(led === 1'b1, "LED on again");

        // ---- blink: flips every BLINK ms
        wr(2'd1, 8'h03);
        e0 = edges;
        ms(4 * BLINK);
        check(edges - e0 >= 3 && edges - e0 <= 5, "blink");
        wr(2'd1, 8'h00); ms(LEDMS + 1);
        check(led === 1'b0, "LED off");

        if (errors == 0) $display("power: ok");
        else             $display("power: %0d FAILED", errors);
        $finish;
    end
endmodule

`default_nettype wire
