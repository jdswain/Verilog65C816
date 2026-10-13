//============================================================================
// tb_adb.v -- exercise the ADB host against a behavioural device model.
//
// The bus is modelled as it really is: open collector, so the line is low if
// EITHER end pulls it down, and idles high through the pull-up.
//
// The "device" decodes bit cells the same way a real one does -- by measuring
// how long the line is held low -- so a host that gets the low/high split
// backwards, or the bit order wrong, fails here rather than on the bench.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_adb;
    localparam integer CLK_HZ = 25_200_000;
    localparam integer US = 1000;            // 1 us, in ns

    reg clk = 0; always #19.84 clk = ~clk;   // 25.2 MHz
    reg rst_n = 0;

    reg  [3:0] reg_addr = 0;
    reg  [7:0] wdata = 0;
    wire [7:0] rdata;
    reg        cs = 0, we = 0;

    wire host_drive;
    reg  dev_drive = 0;
    reg  glitch = 0;                         // injected noise
    reg  contend = 0;                        // a second device holding the bus

    // Open collector: low if anything pulls, otherwise the pull-up wins.
    wire bus = ~(host_drive | dev_drive | glitch | contend);

    // Short noise pulses, well under the deglitch window.
    reg glitching = 0;
    initial forever begin
        @(posedge glitching);
        while (glitching) begin
            #(18 * US); glitch = 1; #(500); glitch = 0;   // 0.5 us low
        end
    end

    adb_host #(.CLK_HZ(CLK_HZ)) dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .wdata(wdata), .rdata(rdata), .cs(cs), .we(we),
        .adb_drive(host_drive), .adb_sense(bus)
    );

    integer errors = 0;

    //------------------------------------------------------------------
    // Register access
    //------------------------------------------------------------------
    task wr(input [3:0] a, input [7:0] d);
        begin
            @(negedge clk); reg_addr = a; wdata = d; we = 1; cs = 1;
            @(negedge clk); cs = 0; we = 0;
        end
    endtask

    task rd(input [3:0] a, output [7:0] d);
        begin
            @(negedge clk); reg_addr = a; we = 0; cs = 1;
            @(negedge clk); d = rdata; cs = 0;
        end
    endtask

    //------------------------------------------------------------------
    // Device model
    //------------------------------------------------------------------
    real t_fall, t_rise, low_us;
    reg [7:0] dev_cmd;
    integer   i, b;

    task dev_send_bit(input v);
        begin
            dev_drive = 1;
            #((v ? 35 : 65) * US);
            dev_drive = 0;
            #((v ? 65 : 35) * US);
        end
    endtask

    task dev_send_byte(input [7:0] d);
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) dev_send_bit(d[k]);
        end
    endtask

    // Measure one incoming bit: the low duration decides the value. `ok` goes
    // low if no bit starts within a bit cell or two, which is how a real device
    // sees the end of a packet -- polled rather than forked, because join_any
    // is SystemVerilog and this is a Verilog-2001 build.
    real t_start;
    task dev_get_bit(output v, output ok);
        begin
            t_start = $realtime;
            ok = 1'b1;
            v  = 1'b0;
            while (bus === 1'b1 && ($realtime - t_start) < 250*US) #200;
            if (bus === 1'b1) begin
                ok = 1'b0;
            end else begin
                t_fall = $realtime;
                @(posedge bus); t_rise = $realtime;
                low_us = (t_rise - t_fall) / 1000.0;
                v = (low_us > 50.0) ? 1'b0 : 1'b1;
            end
        end
    endtask

    reg bitv, bitok;
    reg [7:0] listen_got [0:7];
    integer   listen_n, listen_bits;

    // One transaction, from the device's point of view.
    task dev_transaction(input [7:0] my_addr, input [7:0] talk_b0,
                         input [7:0] talk_b1);
        begin
            // Attention: a low far longer than any bit cell.
            @(negedge bus); t_fall = $realtime;
            @(posedge bus);
            if (($realtime - t_fall) / 1000.0 < 500.0) begin
                $display("FAIL: attention was only %0.0f us", ($realtime-t_fall)/1000.0);
                errors = errors + 1;
            end
            // Sync is the high period we are now in; the first command bit
            // starts at the next falling edge, which dev_get_bit waits for.
            for (b = 7; b >= 0; b = b - 1) begin
                dev_get_bit(bitv, bitok);
                dev_cmd[b] = bitv;
            end
            dev_get_bit(bitv, bitok);            // command stop bit
            if (bitv !== 1'b0) begin
                $display("FAIL: command stop bit was %b, want 0", bitv);
                errors = errors + 1;
            end

            if (dev_cmd[7:4] == my_addr[3:0] && dev_cmd[3:2] == 2'b11) begin
                // Talk: answer after Tlt with a two byte packet.
                #(180 * US);
                dev_send_bit(1'b1);              // start bit
                dev_send_byte(talk_b0);
                dev_send_byte(talk_b1);
                dev_send_bit(1'b0);              // stop bit
            end else if (dev_cmd[7:4] == my_addr[3:0] && dev_cmd[3:2] == 2'b10) begin
                // Listen: collect the host's packet until it stops sending.
                // The final bit received is the stop bit, not data.
                listen_n  = 0;
                listen_bits = 0;
                dev_get_bit(bitv, bitok);        // start bit
                while (bitok && listen_n < 8) begin
                    for (i = 7; i >= 0 && bitok; i = i - 1) begin
                        dev_get_bit(bitv, bitok);
                        if (bitok) listen_got[listen_n][i] = bitv;
                    end
                    if (bitok) listen_n = listen_n + 1;
                end
            end
        end
    endtask

    //------------------------------------------------------------------
    reg [7:0] st, d0, d1;

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (4) @(posedge clk);

        // ---------------- Talk: device 2, register 0 ----------------
        fork
            dev_transaction(8'h02, 8'hA5, 8'h3C);
            begin
                wr(4'h0, 8'h2C);                 // 0010 1100 = dev 2, Talk r0
                rd(4'h1, st);
                if (!st[7]) begin
                    $display("FAIL: busy not set after writing the command");
                    errors = errors + 1;
                end
                // wait for completion
                while (st[7]) begin #(50 * US); rd(4'h1, st); end
            end
        join

        rd(4'h1, st);
        rd(4'h8, d0);
        rd(4'h9, d1);
        $display("Talk: status=%02x (done=%b timeout=%b srq=%b count=%0d) data=%02x %02x",
                 st, st[6], st[5], st[4], st[3:0], d0, d1);
        if (st[5]) begin $display("FAIL: timeout on a device that answered"); errors=errors+1; end
        if (st[3:0] !== 4'd2) begin $display("FAIL: byte count %0d, want 2", st[3:0]); errors=errors+1; end
        if (d0 !== 8'hA5 || d1 !== 8'h3C) begin
            $display("FAIL: got %02x %02x, want a5 3c", d0, d1); errors=errors+1;
        end

        // ---------------- Talk to a device that is not there ----------------
        wr(4'h0, 8'h5C);                          // device 5, Talk r0
        st = 8'hFF;
        while (st[7]) begin #(50 * US); rd(4'h1, st); end
        $display("no device: status=%02x (timeout=%b)", st, st[5]);
        if (!st[5]) begin
            $display("FAIL: no timeout when nothing answered");
            errors = errors + 1;
        end

        // ---------------- Listen: device 2, register 3, two bytes ----------
        wr(4'h8, 8'h5A);
        wr(4'h9, 8'hC3);
        wr(4'h2, 8'd2);                           // length
        fork
            dev_transaction(8'h02, 8'h00, 8'h00);
            begin
                wr(4'h0, 8'h2B);                  // 0010 1011 = dev 2, Listen r3
                st = 8'hFF;
                while (st[7]) begin #(50 * US); rd(4'h1, st); end
            end
        join
        #(400 * US);
        $display("Listen: device received %02x %02x", listen_got[0], listen_got[1]);
        if (listen_got[0] !== 8'h5A || listen_got[1] !== 8'hC3) begin
            $display("FAIL: device got %02x %02x, want 5a c3",
                     listen_got[0], listen_got[1]);
            errors = errors + 1;
        end

        // ---------------- Talk with noise on the bus ----------------
        // 0.5 us glitches, well inside the host's 2 us deglitch window, so it
        // must reject them entirely and still decode the data.
        //
        // The noise is confined to the response phase: the device model here
        // decodes edges directly with no filtering of its own, so glitching it
        // while it receives the command would only prove that the *model* is
        // undeglitched, which is not the thing under test.
        fork
            dev_transaction(8'h02, 8'h96, 8'h69);
            begin
                wr(4'h0, 8'h2C);
                #(1900 * US);          // attention + sync + command + stop
                glitching = 1;         // now the device is replying
                st = 8'hFF;
                while (st[7]) begin #(50 * US); rd(4'h1, st); end
                glitching = 0; glitch = 0;
            end
        join
        glitching = 0; glitch = 0;
        rd(4'h1, st); rd(4'h8, d0); rd(4'h9, d1);
        $display("glitched Talk: status=%02x data=%02x %02x", st, d0, d1);
        if (st[5] || d0 !== 8'h96 || d1 !== 8'h69) begin
            $display("FAIL: noise corrupted the transaction");
            errors = errors + 1;
        end

        // ---------------- collision ----------------
        // A second device holds the bus down through the whole transaction.
        // The host releases the line between bits and must notice it staying
        // low outside the service-request window.
        rd(4'h3, d0);
        if (d0[0]) begin
            $display("FAIL: collision already set before the test");
            errors = errors + 1;
        end
        contend = 1;
        wr(4'h2, 8'd2);
        wr(4'h0, 8'h2B);                      // Listen, so the host transmits
        st = 8'hFF;
        while (st[7]) begin #(50 * US); rd(4'h1, st); end
        contend = 0;
        rd(4'h3, d0);
        $display("collision: extended status=%02x", d0);
        if (!d0[0]) begin
            $display("FAIL: a held-down bus was not reported as a collision");
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS"); else $display("FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #120_000_000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
