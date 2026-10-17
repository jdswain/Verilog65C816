//============================================================================
// sound.v -- two SIDs on the board's I2S amplifier
//
// The SIDs are reDIP SID's emulation (rtl/sid/, CERN-OHL-S v2), one pipeline
// that emulates two chips. This module is what sits between it and the SoC:
//
//   $0500-$051F  SID 1 registers, as $D400-$D41F on a C64
//   $0520-$053F  SID 2 registers
//   $0540        control (mirrored to $057F):
//                  bit 0  amplifier on (pin 51), resets to 1
//                  bit 1  stereo: SID 1 left, SID 2 right. 0 (reset) puts
//                         the mix of both in both channels, which is what
//                         the board's mono amplifier needs
//                  bit 2  SID 1 is an 8580 (0: 6581)
//                  bit 3  SID 2 is an 8580
//                read: bits 3-0 as written, bit 6 a write was lost because
//                the queue was full (cleared by writing the control
//                register), bit 7 writes are still queued
//
// The SID clock is a clock enable of 985248 Hz (PAL) made from the 25.2 MHz
// system clock, giving the pipeline the 25 or 26 cycles a SID cycle that it
// needs (at least 20). The SID's bus changes only as phi2 rises and holds
// for the whole SID cycle, which covers both where reDIP reads (phi2 high)
// and where it writes (the first six cycles after phi2 falls).
//
// Writes are posted: they go into a 64-entry queue and the CPU carries on.
// One leaves the queue each SID cycle, in order, so a register dump is
// played out over a few tens of microseconds, and timed tricks such as
// samples through the volume register keep their timing. Software that
// must know a write has reached the SID can wait for bit 7 to clear.
//
// Reads never wait either. In SID cycles with nothing to write, the SID is
// read for OSC3 and ENV3 of each chip in turn, and those reads return the
// latest value. POTX and POTY read $FF (nothing is connected) and the
// write-only registers read 0.
//
// Audio: each SID gives a 24-bit sample every SID cycle. A one-pole lowpass
// at about 20 kHz, run at that rate, takes off most of what would alias, and
// the I2S transmitter takes its output 49.2 kHz times a second: BCLK is
// 25.2 MHz / 8 and a frame is 64 bits, 24 used in each half. The MAX98357A
// on the board plays the left channel, because pin 51 drives its SD_MODE
// high; a stereo DAC on the same three pins gets both.
//============================================================================
`default_nettype none

module sound #(
    parameter integer SYS_HZ = 25_200_000,
    parameter integer SID_HZ = 985_248
) (
    input  wire       clk,
    input  wire       rst_n,
    // register interface: $0500-$057F
    input  wire [6:0] addr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata,
    input  wire       cs,               // access this cycle
    input  wire       we,
    // I2S and the amplifier
    output reg        i2s_bclk,
    output reg        i2s_lrck,
    output reg        i2s_din,
    output wire       amp_en
);
    //------------------------------------------------------------------
    // Control register
    //------------------------------------------------------------------
    reg [3:0] ctrl;
    reg       lost;
    wire      queued;

    assign amp_en = ctrl[0];

    //------------------------------------------------------------------
    // phi2: a numerically controlled oscillator. Its top bit is phi2.
    //------------------------------------------------------------------
    localparam [23:0] PHI_INC = (SID_HZ * 64'd16777216 + SYS_HZ/2) / SYS_HZ;

    reg [23:0] phase;
    wire [23:0] phase_next = phase + PHI_INC;
    wire       phi2_rise = ~phase[23] & phase_next[23];
    wire       phi2_fall =  phase[23] & ~phase_next[23];

    // SID reset: held while the SoC is in reset and for 16 SID cycles after,
    // so that it is seen by the SID's own pipeline.
    reg [4:0] res_cnt;
    wire      sid_res = ~res_cnt[4];

    //------------------------------------------------------------------
    // Write queue: {SID, register, data}
    //------------------------------------------------------------------
    reg [13:0] q [0:63];
    reg [5:0]  q_wr, q_rd;
    reg [6:0]  q_count;
    assign queued = (q_count != 7'd0);

    wire cpu_write_sid = cs & we & ~addr[6];
    wire q_full        = q_count[6];
    wire q_push        = cpu_write_sid & ~q_full;
    wire q_pop         = phi2_rise & queued & ~sid_res;

    always @(posedge clk) if (q_push) q[q_wr] <= {addr[5], addr[4:0], wdata};
    wire [13:0] q_head = q[q_rd];

    //------------------------------------------------------------------
    // The SID's bus, changed only as phi2 rises
    //------------------------------------------------------------------
    reg       b_sid;                    // 1 = SID 2
    reg [4:0] b_addr;
    reg [7:0] b_data;
    reg       b_rw_n;
    reg       b_read;                   // this cycle is a shadow read
    reg [1:0] shadow_sel;               // which register to read next
    reg [7:0] osc3 [0:1];
    reg [7:0] env3 [0:1];

    wire [7:0]  sid_data_o;
    wire [47:0] sid_audio_o;
    wire        sid_pot_o;

    wire [15:0] bus_i = {b_addr, b_data, phase[23], b_rw_n, sid_res};
    // cs_t: {cs_n, cs_io1_n, a8, a5}; SID 2 is selected by a5.
    wire [3:0]  cs_i  = {1'b0, 1'b1, 1'b0, b_sid};

    sid_api u_sid (
        .clk(clk), .bus_i(bus_i), .cs(cs_i), .data_o(sid_data_o),
        .pot_i(2'b00), .pot_o(sid_pot_o),
        .audio_i(48'd0), .audio_o(sid_audio_o),
        .model_sel(ctrl[3:2])
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase      <= 24'd0;
            res_cnt    <= 5'd0;
            q_wr       <= 6'd0;
            q_rd       <= 6'd0;
            q_count    <= 7'd0;
            b_sid      <= 1'b0;
            b_addr     <= 5'h1b;
            b_data     <= 8'd0;
            b_rw_n     <= 1'b1;
            b_read     <= 1'b0;
            shadow_sel <= 2'd0;
            osc3[0] <= 8'd0; osc3[1] <= 8'd0;
            env3[0] <= 8'd0; env3[1] <= 8'd0;
            ctrl       <= 4'b0001;
            lost       <= 1'b0;
            rdata      <= 8'd0;
        end else begin
            phase <= phase_next;

            if (phi2_rise & sid_res) res_cnt <= res_cnt + 1'b1;

            // Queue bookkeeping
            if (q_push) q_wr <= q_wr + 1'b1;
            if (q_pop)  q_rd <= q_rd + 1'b1;
            q_count <= q_count + {6'd0, q_push} - {6'd0, q_pop};
            if (cpu_write_sid & q_full) lost <= 1'b1;

            // Capture a shadow read while phi2 is high, so the last value
            // before it falls is the one kept.
            if (phase[23] & b_read) begin
                if (b_addr[0]) osc3[b_sid] <= sid_data_o;    // $1B
                else           env3[b_sid] <= sid_data_o;    // $1C
            end

            // Next SID cycle: a queued write, or the next shadow read.
            if (phi2_rise) begin
                if (q_pop) begin
                    {b_sid, b_addr, b_data} <= q_head;
                    b_rw_n <= 1'b0;
                    b_read <= 1'b0;
                end else begin
                    b_sid      <= shadow_sel[1];
                    b_addr     <= shadow_sel[0] ? 5'h1c : 5'h1b;
                    b_rw_n     <= 1'b1;
                    b_read     <= ~sid_res;
                    shadow_sel <= shadow_sel + 1'b1;
                end
            end

            // CPU side
            if (cs & we & addr[6]) begin
                ctrl <= wdata[3:0];
                lost <= 1'b0;
            end
            if (cs & ~we) begin
                if (addr[6])                    rdata <= {queued, lost, 2'b00, ctrl};
                else if (addr[4:0] == 5'h1b)    rdata <= osc3[addr[5]];
                else if (addr[4:0] == 5'h1c)    rdata <= env3[addr[5]];
                else if (addr[4:0] == 5'h19 ||
                         addr[4:0] == 5'h1a)    rdata <= 8'hFF;
                else                            rdata <= 8'h00;
            end
        end
    end

    //------------------------------------------------------------------
    // Lowpass, one pole: y += (x - y) / 8 each SID cycle, about 20 kHz.
    //------------------------------------------------------------------
    wire signed [23:0] x_l = sid_audio_o[47:24];    // SID 1
    wire signed [23:0] x_r = sid_audio_o[23:0];     // SID 2
    reg  signed [26:0] y_l, y_r;                    // 3 fraction bits

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_l <= 27'sd0;
            y_r <= 27'sd0;
        end else if (phi2_fall) begin
            y_l <= y_l + ({{3{x_l[23]}}, x_l} - (y_l >>> 3));
            y_r <= y_r + ({{3{x_r[23]}}, x_r} - (y_r >>> 3));
        end
    end

    // y is x scaled by 8 in steady state; take back the 24 bits.
    wire signed [23:0] o_l = y_l[26:3];
    wire signed [23:0] o_r = y_r[26:3];
    wire signed [24:0] mix = {o_l[23], o_l} + {o_r[23], o_r};

    //------------------------------------------------------------------
    // I2S: 512 system clocks a frame, BCLK = clk / 8, 64 bits a frame.
    // LRCK low is the left channel; each word's MSB follows one BCLK after
    // LRCK changes; data and LRCK change as BCLK falls.
    //------------------------------------------------------------------
    reg [8:0]  fcnt;
    reg [23:0] word_l, word_r;

    wire [5:0] slot = fcnt[8:3];        // 0-63
    wire [4:0] bitn = slot[4:0];        // within the half
    wire [23:0] word = slot[5] ? word_r : word_l;
    wire       bit_out = (bitn >= 5'd1 && bitn <= 5'd24) ? word[5'd24 - bitn] : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fcnt     <= 9'd0;
            word_l   <= 24'd0;
            word_r   <= 24'd0;
            i2s_bclk <= 1'b0;
            i2s_lrck <= 1'b0;
            i2s_din  <= 1'b0;
        end else begin
            fcnt <= fcnt + 1'b1;
            if (fcnt == 9'd511) begin
                // The next frame's samples, taken at once so the two halves
                // belong together.
                word_l <= ctrl[1] ? o_l : mix[24:1];
                word_r <= ctrl[1] ? o_r : mix[24:1];
            end
            i2s_bclk <= fcnt[2];
            i2s_lrck <= fcnt[8];
            i2s_din  <= bit_out;
        end
    end
endmodule

`default_nettype wire
