//============================================================================
// adb_kbd_model.v -- a behavioural ADB keyboard, for simulation only.
//
// Sits at one address and answers Talk register 0 with the next queued packet
// of two key events, or stays silent if nothing is queued -- which is what a
// real keyboard does when no key has changed. Every other command is ignored.
//
// It decodes the host the way a device does, by measuring how long the line is
// held low, and its own timing is in units of the US parameter so it can follow
// a testbench whose clock is not the real 25.2 MHz.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module adb_kbd_model #(
    parameter real      US   = 1000.0,   // one "microsecond" of bus time, in ns
    parameter [3:0]     ADDR = 4'd2
) (
    input  wire bus,                     // the open-collector line, 1 = idle
    output reg  drive                    // 1 = this device pulls it low
);
    reg [15:0] queue [0:255];
    integer    head = 0, tail = 0, answered = 0;

    // Queue one packet: two events, $FF meaning "no second event".
    task push(input [7:0] e0, input [7:0] e1);
        begin
            queue[tail] = {e0, e1};
            tail = tail + 1;
        end
    endtask

    task send_bit(input v);
        begin
            drive = 1'b1; #((v ? 35 : 65) * US);
            drive = 1'b0; #((v ? 65 : 35) * US);
        end
    endtask

    real    t_fall, t_wait;
    reg     bitv, bitok;
    reg [7:0] cmd;
    integer b, k;

    task get_bit(output v, output ok);
        begin
            t_wait = $realtime;
            ok = 1'b1; v = 1'b0;
            while (bus === 1'b1 && ($realtime - t_wait) < 250 * US) #(US / 4);
            if (bus === 1'b1) ok = 1'b0;
            else begin
                t_fall = $realtime;
                @(posedge bus);
                v = (($realtime - t_fall) > 50 * US) ? 1'b0 : 1'b1;
            end
        end
    endtask

    initial begin
        drive = 1'b0;
        forever begin
            // Attention: a low far longer than any bit cell.
            @(negedge bus); t_fall = $realtime;
            @(posedge bus);
            if (($realtime - t_fall) > 500 * US) begin
                bitok = 1'b1;
                for (b = 7; b >= 0 && bitok; b = b - 1) begin
                    get_bit(bitv, bitok);
                    cmd[b] = bitv;
                end
                if (bitok) get_bit(bitv, bitok);         // command stop bit
                if (bitok && cmd == {ADDR, 4'b1100} && head != tail) begin
                    #(180 * US);                         // Tlt
                    send_bit(1'b1);                      // start
                    for (k = 15; k >= 0; k = k - 1) send_bit(queue[head][k]);
                    send_bit(1'b0);                      // stop
                    head = head + 1;
                    answered = answered + 1;
                end
            end
        end
    end
endmodule

`default_nettype wire
