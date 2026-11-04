//============================================================================
// tmds_encoder.v -- DVI/HDMI 8b/10b TMDS encoder (one channel)
//
// The published algorithm: first re-code the byte with XOR or XNOR to minimise
// transitions, then optionally invert to steer the running DC disparity back
// towards zero. During blanking the channel sends one of four fixed control
// tokens instead, chosen by the two control bits -- these have deliberately
// high transition counts so a receiver can lock to them.
//
// The two steps are a clock apart: the first's result and its count of ones
// are registered, and the balancing works from those. Done in one clock, the
// path from the palette through both steps to the disparity count was the
// pixel domain's critical path at 1024x768 -- 19 ps of slack at 64.8 MHz, and
// data dependent, so a colour like OS16's desktop could upset the balancing
// and lose the monitor's lock. The extra clock delays every channel and the
// syncs alike.
//============================================================================
`default_nettype none

module tmds_encoder (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] din,        // pixel component
    input  wire [1:0] ctrl,       // control bits, used while blanking
    input  wire       de,         // 1 = pixel data, 0 = control period
    output reg  [9:0] dout
);
    // stage 1: transition minimisation
    wire [3:0] n1d = din[0] + din[1] + din[2] + din[3] +
                     din[4] + din[5] + din[6] + din[7];
    wire use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && din[0] == 1'b0);

    wire [8:0] q_m;
    assign q_m[0] = din[0];
    assign q_m[1] = use_xnor ? ~(q_m[0] ^ din[1]) : (q_m[0] ^ din[1]);
    assign q_m[2] = use_xnor ? ~(q_m[1] ^ din[2]) : (q_m[1] ^ din[2]);
    assign q_m[3] = use_xnor ? ~(q_m[2] ^ din[3]) : (q_m[2] ^ din[3]);
    assign q_m[4] = use_xnor ? ~(q_m[3] ^ din[4]) : (q_m[3] ^ din[4]);
    assign q_m[5] = use_xnor ? ~(q_m[4] ^ din[5]) : (q_m[4] ^ din[5]);
    assign q_m[6] = use_xnor ? ~(q_m[5] ^ din[6]) : (q_m[5] ^ din[6]);
    assign q_m[7] = use_xnor ? ~(q_m[6] ^ din[7]) : (q_m[6] ^ din[7]);
    assign q_m[8] = use_xnor ? 1'b0 : 1'b1;

    wire [3:0] n1q_c = q_m[0] + q_m[1] + q_m[2] + q_m[3] +
                       q_m[4] + q_m[5] + q_m[6] + q_m[7];

    reg  [8:0] q_m_r;
    reg  [3:0] n1q;
    reg  [1:0] ctrl_r;
    reg        de_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_m_r  <= 9'd0;
            n1q    <= 4'd0;
            ctrl_r <= 2'b00;
            de_r   <= 1'b0;
        end else begin
            q_m_r  <= q_m;
            n1q    <= n1q_c;
            ctrl_r <= ctrl;
            de_r   <= de;
        end
    end

    // stage 2: DC balancing, a clock later
    wire [3:0] n0q = 4'd8 - n1q;

    // Running disparity. Six bits and explicitly signed: mixing a signed reg
    // with unsigned operands makes Verilog evaluate the whole expression as
    // unsigned, which silently destroys the balancing.
    reg signed [5:0] cnt;
    wire signed [5:0] s_n1q = $signed({2'b00, n1q});
    wire signed [5:0] s_n0q = $signed({2'b00, n0q});
    wire balanced = (n1q == n0q);
    wire same_sign = (cnt > 0 && n1q > n0q) || (cnt < 0 && n0q > n1q);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= 6'sd0;
            dout <= 10'b1101010100;
        end else if (!de_r) begin
            // control period: fixed tokens, disparity resets
            case (ctrl_r)
            2'b00: dout <= 10'b1101010100;
            2'b01: dout <= 10'b0010101011;
            2'b10: dout <= 10'b0101010100;
            2'b11: dout <= 10'b1010101011;
            endcase
            cnt <= 6'sd0;
        end else if (cnt == 0 || balanced) begin
            dout <= {~q_m_r[8], q_m_r[8], q_m_r[8] ? q_m_r[7:0] : ~q_m_r[7:0]};
            cnt  <= q_m_r[8] ? (cnt + s_n1q - s_n0q)
                           : (cnt + s_n0q - s_n1q);
        end else if (same_sign) begin
            dout <= {1'b1, q_m_r[8], ~q_m_r[7:0]};
            cnt  <= cnt + (q_m_r[8] ? 6'sd2 : 6'sd0) + (s_n0q - s_n1q);
        end else begin
            dout <= {1'b0, q_m_r[8], q_m_r[7:0]};
            cnt  <= cnt - (q_m_r[8] ? 6'sd0 : 6'sd2) + (s_n1q - s_n0q);
        end
    end
endmodule

`default_nettype wire
