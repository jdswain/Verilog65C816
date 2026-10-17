// tb_sound.v -- sound.v against the sid_api stub: posted writes reach the
// SID in order, shadow reads, the control register, and the I2S frames.
//
//   iverilog -g2005 -o sound_sim rtl/sound.v sim/sid_api_stub.v sim/tb_sound.v
//   vvp sound_sim
`timescale 1ns/1ps
`default_nettype none
module tb_sound;
    reg clk = 0; always #19.841 clk = ~clk;     // 25.2 MHz
    reg rst_n = 0;
    reg [6:0] addr = 0; reg [7:0] wdata = 0; wire [7:0] rdata;
    reg cs = 0, we = 0;
    wire bclk, lrck, din, amp_en;

    sound dut (.clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata),
               .rdata(rdata), .cs(cs), .we(we), .i2s_bclk(bclk),
               .i2s_lrck(lrck), .i2s_din(din), .amp_en(amp_en));

    integer errors = 0;
    task wr(input [6:0] a, input [7:0] v);
        begin @(negedge clk); addr = a; wdata = v; we = 1; cs = 1;
              @(negedge clk); cs = 0; we = 0; end
    endtask
    task rd(input [6:0] a, output [7:0] v);
        begin @(negedge clk); addr = a; we = 0; cs = 1;
              @(negedge clk); cs = 0; v = rdata; end
    endtask
    task check(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL: %0s: got %0h, want %0h", what, got, want);
            errors = errors + 1;
        end
    endtask

    // Receive one I2S frame: 32 bits a half, MSB one BCLK after LRCK.
    task frame(output [23:0] l, output [23:0] r);
        integer i; reg [63:0] bits;
        begin
            @(negedge lrck);                     // start of a left half
            for (i = 0; i < 64; i = i + 1) begin
                @(posedge bclk); bits = {bits[62:0], din};
            end
            l = bits[62:39];
            r = bits[30:7];
        end
    endtask

    reg [7:0] v;
    reg [23:0] l, r;
    integer i;
    initial begin
        repeat (4) @(posedge clk); rst_n = 1;

        rd(7'h40, v);  check("control after reset", v, 8'h01);
        if (!amp_en) begin $display("FAIL: amplifier off after reset"); errors = errors + 1; end

        // A burst of writes, faster than the SID takes them.
        for (i = 0; i < 25; i = i + 1) wr(i[6:0], 8'h10 + i[7:0]);
        wr(7'h38, 8'h40);                         // SID 2 register $18
        rd(7'h40, v);  check("queued", v[7], 1);
        repeat (40 * 26) @(posedge clk);
        rd(7'h40, v);  check("queue drained", v[7], 0);
        check("writes logged", dut.u_sid.nlog, 26);
        for (i = 0; i < 25; i = i + 1)
            check("write order", dut.u_sid.log[i], {1'b0, i[4:0], 8'h10 + i[7:0]});
        check("SID 2 write", dut.u_sid.log[25], {1'b1, 5'h18, 8'h40});

        // Shadow reads
        repeat (8 * 26) @(posedge clk);
        rd(7'h1b, v); check("SID 1 OSC3", v, 8'hA0);
        rd(7'h1c, v); check("SID 1 ENV3", v, 8'hB0);
        rd(7'h3b, v); check("SID 2 OSC3", v, 8'hA1);
        rd(7'h3c, v); check("SID 2 ENV3", v, 8'hB1);
        rd(7'h19, v); check("POTX", v, 8'hFF);
        rd(7'h00, v); check("write-only register", v, 8'h00);

        // Audio: SID 1 has $18 = $28 written (i = 24 above: $10 + $18),
        // SID 2 $40. Let the lowpass settle, then mono is their mean.
        repeat (200000) @(posedge clk);
        frame(l, r);
        check("mono left",  l, 24'h340000);
        check("mono right", r, 24'h340000);
        wr(7'h40, 8'h03);                        // stereo, amplifier on
        frame(l, r); frame(l, r);
        check("stereo left",  l, 24'h280000);
        check("stereo right", r, 24'h400000);

        wr(7'h40, 8'h00);
        if (amp_en) begin $display("FAIL: amplifier still on"); errors = errors + 1; end

        if (errors == 0) $display("PASS"); else $display("%0d errors", errors);
        $finish;
    end
endmodule
`default_nettype wire
