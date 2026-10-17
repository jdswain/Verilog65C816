// sid_api_stub.v -- stands in for reDIP SID's sid_api (rtl/sid/) in Icarus
// simulations, which cannot parse its SystemVerilog. Same ports, flattened.
//
// It takes a write as phi2 falls, as reDIP does, and logs it for the test
// bench. Its audio is the last value written to register $18 of each SID,
// as the top byte of a 24-bit sample. Reads of $1B and $1C return $A0 and
// $B0, plus 1 for SID 2.
`default_nettype none
module sid_api (
    input  wire        clk,
    input  wire [15:0] bus_i,       // {addr[4:0], data, phi2, r_w_n, res}
    input  wire [3:0]  cs,          // {cs_n, cs_io1_n, a8, a5}
    output wire [7:0]  data_o,
    input  wire [1:0]  pot_i,
    output wire        pot_o,
    input  wire [47:0] audio_i,
    output reg  [47:0] audio_o,
    input  wire [1:0]  model_sel
);
    wire [4:0] a    = bus_i[15:11];
    wire [7:0] d    = bus_i[10:3];
    wire       phi2 = bus_i[2];
    wire       rw_n = bus_i[1];
    wire       sid2 = cs[0];

    reg phi2_prev = 1'b0;
    integer nlog = 0;
    reg [13:0] log [0:255];

    initial audio_o = 48'd0;

    always @(posedge clk) begin
        phi2_prev <= phi2;
        if (phi2_prev & ~phi2 & ~rw_n & ~cs[3]) begin
            log[nlog] <= {sid2, a, d};
            nlog <= nlog + 1;
            if (a == 5'h18) begin
                if (sid2) audio_o[23:0]  <= {d, 16'd0};
                else      audio_o[47:24] <= {d, 16'd0};
            end
        end
    end

    assign data_o = (phi2 & rw_n & (a == 5'h1b)) ? 8'hA0 + sid2 :
                    (phi2 & rw_n & (a == 5'h1c)) ? 8'hB0 + sid2 : 8'h00;
    assign pot_o  = 1'b0;
endmodule
`default_nettype wire
