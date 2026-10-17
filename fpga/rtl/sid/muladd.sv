// ----------------------------------------------------------------------------
// This file is part of reDIP SID, a MOS 6581/8580 SID FPGA emulation platform.
// Copyright (C) 2022 - 2023  Dag Lem <resid@nimrod.no>
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.
//
// You may redistribute and modify this source and make products using it under
// the terms of the CERN-OHL-S v2 (https://ohwr.org/cern_ohl_s_v2.txt).
//
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.
//
// Source location: https://github.com/daglem/reDIP-SID
//
// Modified 2026-10-16 for the Verilog65C816 SoC (fpga/rtl/sid/README.md):
//   The iCE40 SB_MAC16 replaced by a generic multiply-add, which Gowin maps
//   onto a DSP block.
// ----------------------------------------------------------------------------

// Hardware 16x16->32 multiply-add: o = c + a*b, or c - a*b when s is set.
module muladd (
    input  logic signed [31:0] c,
    input  logic               s,
    input  logic signed [15:0] a,
    input  logic signed [15:0] b,
    output logic signed [31:0] o
);
    logic signed [31:0] m;
    assign m = a * b;
    assign o = s ? c - m : c + m;
endmodule
