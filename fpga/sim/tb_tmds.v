//============================================================================
// tb_tmds.v -- check the TMDS encoder against the properties that matter:
//   * every encoded word decodes back to the byte that went in
//   * the running DC disparity stays bounded (that is the whole point of the
//     second stage; an unbounded count means a monitor loses lock)
//   * control tokens appear during blanking
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_tmds;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg [7:0] din = 0;
    reg [1:0] ctrl = 0;
    reg de = 0;
    wire [9:0] dout;

    tmds_encoder dut(.clk(clk), .rst_n(rst_n), .din(din), .ctrl(ctrl),
                     .de(de), .dout(dout));

    integer errors = 0, i, rep;
    integer max_disp = 0;
    reg [7:0] expect_q [0:1023];
    integer wp = 0;

    // Reverse the encoding to recover the original byte.
    function [7:0] tmds_decode(input [9:0] w);
        reg [7:0] q;
        integer k;
        begin
            q = w[9] ? ~w[7:0] : w[7:0];
            tmds_decode[0] = q[0];
            for (k = 1; k < 8; k = k + 1)
                tmds_decode[k] = w[8] ? (q[k] ^ q[k-1]) : ~(q[k] ^ q[k-1]);
        end
    endfunction

    reg [7:0] sent [0:3];
    integer si = 0;

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;

        // ---- control tokens while blanking ----
        de = 0;
        for (i = 0; i < 4; i = i + 1) begin
            ctrl = i[1:0];
            @(posedge clk); @(posedge clk);
            case (i)
            0: if (dout !== 10'b1101010100) begin $display("FAIL ctrl 00 = %b", dout); errors=errors+1; end
            1: if (dout !== 10'b0010101011) begin $display("FAIL ctrl 01 = %b", dout); errors=errors+1; end
            2: if (dout !== 10'b0101010100) begin $display("FAIL ctrl 10 = %b", dout); errors=errors+1; end
            3: if (dout !== 10'b1010101011) begin $display("FAIL ctrl 11 = %b", dout); errors=errors+1; end
            endcase
        end
        $display("control tokens: %0d error(s)", errors);

        // ---- round-trip every byte, several times over, tracking disparity ----
        de = 1;
        for (rep = 0; rep < 4; rep = rep + 1) begin
            for (i = 0; i < 256; i = i + 1) begin
                din = i[7:0];
                @(posedge clk);
                #1;
                // dout corresponds to the din presented one clock earlier
                // dout is registered, so after this edge it holds encode(din)
                if (tmds_decode(dout) !== din) begin
                    if (errors < 5)
                        $display("FAIL round-trip: sent %02x, encoded %b, decoded %02x",
                                 din, dout, tmds_decode(dout));
                    errors = errors + 1;
                end
                if (dut.cnt > max_disp)  max_disp = dut.cnt;
                if (-dut.cnt > max_disp) max_disp = -dut.cnt;
            end
        end
        $display("round-trip:     %0d error(s) over 1024 encodings", errors);
        $display("max |disparity| = %0d", max_disp);
        if (max_disp > 8) begin
            $display("FAIL: disparity is not being bounded");
            errors = errors + 1;
        end

        // ---- constant streams: a solid-colour screen is the worst case for
        // ---- the balancer, and is exactly what a blank display sends
        for (rep = 0; rep < 3; rep = rep + 1) begin
            din = (rep == 0) ? 8'h00 : (rep == 1) ? 8'hFF : 8'hAA;
            max_disp = 0;
            for (i = 0; i < 300; i = i + 1) begin
                @(posedge clk); #1;
                if (tmds_decode(dout) !== din) begin
                    $display("FAIL constant %02x round-trip", din);
                    errors = errors + 1; i = 300;
                end
                if (dut.cnt > max_disp)  max_disp = dut.cnt;
                if (-dut.cnt > max_disp) max_disp = -dut.cnt;
            end
            $display("constant %02x: max |disparity| = %0d", din, max_disp);
            if (max_disp > 10) begin
                $display("FAIL: disparity unbounded on a constant stream");
                errors = errors + 1;
            end
        end

        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end
endmodule

`default_nettype wire
