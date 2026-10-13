//============================================================================
// sdram_model.v -- behavioural model of the GW2AR-18's in-package SDRAM
//
// 4 banks x 2048 rows x 256 columns x 32 bits, written to the datasheet
// definition of the protocol rather than to match any particular controller:
//
//   - commands are captured on the rising edge of the SDRAM clock
//   - read data appears CAS clocks after the READ command is captured, and
//     continues for the burst length programmed in the mode register
//   - writes are single-location when mode register bit 9 is set
//   - a column access requires its bank's row to be open (ACTIVE) first
//   - DQM masks byte lanes on writes and is ignored on reads here
//
// It complains loudly about protocol violations (access to a closed row, a
// read before initialization, out-of-range address) so mistakes surface in
// simulation instead of as silence on hardware.
//
// Storage is a small window: MEM_WORDS words indexed by {row,bank,col}. Tests
// must stay inside it, which the model checks.
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module sdram_model #(
    parameter integer MEM_WORDS = 16384,
    parameter integer CAS       = 2,
    parameter         VERBOSE   = 0
) (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [10:0] a,
    input  wire [1:0]  ba,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);
    reg [31:0] mem [0:MEM_WORDS-1];
    // Set +quiet_range when a test deliberately runs off the modelled window.
    reg quiet_range = 1'b0;
    initial if ($test$plusargs("quiet_range")) quiet_range = 1'b1;

    reg [10:0] open_row [0:3];
    reg        row_open [0:3];
    reg        initialized = 1'b0;
    reg        mode_set    = 1'b0;
    reg [2:0]  burst_code  = 3'd0;      // mode register M2:M0
    reg        single_wr   = 1'b0;      // mode register M9

    function integer burst_len(input [2:0] code);
        case (code)
        3'd0: burst_len = 1;
        3'd1: burst_len = 2;
        3'd2: burst_len = 4;
        3'd3: burst_len = 8;
        default: burst_len = 1;         // full page not modelled
        endcase
    endfunction

    // Read pipeline: data becomes visible CAS clocks after the command, and a
    // burst occupies several consecutive slots, so this must be deep enough for
    // CAS + the longest burst.
    localparam integer PIPE = 12;
    reg [31:0] pipe_data [0:PIPE-1];
    reg        pipe_vld  [0:PIPE-1];
    integer    i;

    // Bursts wrap within an aligned block of burst_len columns.
    function [7:0] col_wrap(input [7:0] start, input integer n);
        reg [7:0] mask;
        begin
            mask = burst_len(burst_code) - 1;
            col_wrap = (start & ~mask) | ((start + n[7:0]) & mask);
        end
    endfunction

    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'hDEAD_BEEF;
        for (i = 0; i < 4; i = i + 1) begin
            row_open[i] = 1'b0; open_row[i] = 11'd0;
        end
        for (i = 0; i < PIPE; i = i + 1) begin
            pipe_vld[i] = 1'b0; pipe_data[i] = 32'd0;
        end
    end

    assign dq = pipe_vld[0] ? pipe_data[0] : 32'hzzzz_zzzz;

    wire [2:0] cmd = {ras_n, cas_n, we_n};
    localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101,
                     C_WR  = 3'b100, C_PRE = 3'b010, C_REF = 3'b001,
                     C_MRS = 3'b000;

    function integer index(input [10:0] r, input [1:0] b, input [7:0] c);
        index = (r * 1024) + (b * 256) + c;
    endfunction

    task check_range(input integer idx);
        if (idx >= MEM_WORDS && !quiet_range)
            $display("SDRAM MODEL: address out of modelled range (index %0d >= %0d)",
                     idx, MEM_WORDS);
    endtask

    integer idx;

    always @(posedge clk) begin
        // advance the CAS pipeline
        for (i = 0; i < PIPE-1; i = i + 1) begin
            pipe_vld[i]  <= pipe_vld[i+1];
            pipe_data[i] <= pipe_data[i+1];
        end
        pipe_vld[PIPE-1] <= 1'b0;

        if (cke && !cs_n) begin
            case (cmd)
            C_MRS: begin
                mode_set    <= 1'b1;
                initialized <= 1'b1;
                burst_code  <= a[2:0];
                single_wr   <= a[9];
                if (VERBOSE)
                    $display("SDRAM: mode register <= %b (burst %0d, %s writes)",
                             a, burst_len(a[2:0]), a[9] ? "single" : "burst");
            end
            C_REF: begin
                if (!row_open[0] && !row_open[1] && !row_open[2] && !row_open[3]) ;
                else $display("SDRAM MODEL: refresh with a row still open");
            end
            C_PRE: begin
                if (a[10]) begin
                    for (i = 0; i < 4; i = i + 1) row_open[i] <= 1'b0;
                end else begin
                    row_open[ba] <= 1'b0;
                end
            end
            C_ACT: begin
                if (row_open[ba])
                    $display("SDRAM MODEL: ACTIVE on bank %0d whose row is already open", ba);
                row_open[ba] <= 1'b1;
                open_row[ba] <= a;
                if (VERBOSE) $display("SDRAM: activate bank %0d row %0d", ba, a);
            end
            C_RD: begin
                if (!initialized) $display("SDRAM MODEL: READ before mode register set");
                if (!row_open[ba]) $display("SDRAM MODEL: READ with no open row on bank %0d", ba);
                // Queue the whole burst: word n appears CAS+n clocks later.
                // Column address wraps within the burst boundary.
                for (i = 0; i < burst_len(burst_code); i = i + 1) begin
                    idx = index(open_row[ba], ba, col_wrap(a[7:0], i));
                    check_range(idx);
                    pipe_data[CAS-1+i] <= mem[idx];
                    pipe_vld[CAS-1+i]  <= 1'b1;
                    if (VERBOSE)
                        $display("SDRAM: read  [%0d] = %08x (beat %0d)", idx, mem[idx], i);
                end
                if (a[10]) row_open[ba] <= 1'b0;      // auto-precharge
            end
            C_WR: begin
                if (!initialized) $display("SDRAM MODEL: WRITE before mode register set");
                if (!row_open[ba]) $display("SDRAM MODEL: WRITE with no open row on bank %0d", ba);
                idx = index(open_row[ba], ba, a[7:0]);
                check_range(idx);
                if (!dqm[0]) mem[idx][7:0]   <= dq[7:0];
                if (!dqm[1]) mem[idx][15:8]  <= dq[15:8];
                if (!dqm[2]) mem[idx][23:16] <= dq[23:16];
                if (!dqm[3]) mem[idx][31:24] <= dq[31:24];
                if (a[10]) row_open[ba] <= 1'b0;      // auto-precharge
                if (VERBOSE) $display("SDRAM: write [%0d] <= %08x dqm=%b", idx, dq, dqm);
            end
            default: ;
            endcase
        end
    end
endmodule

`default_nettype wire
