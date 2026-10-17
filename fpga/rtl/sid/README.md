# reDIP SID

The SID emulation from [reDIP SID](https://github.com/daglem/reDIP-SID), a
MOS 6581/8580 SID FPGA emulation platform by Dag Lem, taken from its
`gateware/` directory at commit `5660867` ("Correct MOS6581 combined
waveforms"). One time-shared pipeline emulates two SID chips.

Copyright (C) 2022 - 2023 Dag Lem <resid@nimrod.no>. It describes Open
Hardware and is licensed under the CERN-OHL-S v2 (`LICENSE` at the top of this
repository), as is the rest of this repository.

`../sound.v` connects it to the SoC; see the Sound section of
`fpga/README.md`.

## What was taken

The SID core, `sid_api` and below: `sid_pkg.sv`, `sid_api.sv`,
`sid_control.sv`, `sid_voice.sv`, `sid_waveform.sv` (with its two `.svh`
files), `sid_envelope.sv`, `sid_dac.sv`, `sid_filter.sv`, `sid_pot.sv`,
`muladd.sv` and the lookup tables (`*.hex`).

Not taken: the reDIP SID board's top level, its I/O, PLL, I2C and codec
initialisation, and the I2S interface, which are specific to its iCE40UP5K
and SGTL5000; `sound.v` does that work here.

## Changes

Each changed file says so in its header, with the date. On 2026-10-16:

- **`default_nettype none` removed** from every file. Gowin's synthesiser
  rejects `input logic` ports under it.
- **`muladd.sv`**: the iCE40 `SB_MAC16` replaced by a generic multiply-add,
  which Gowin maps onto a DSP block.
- **`sid_dac.sv`**: uses the precomputed DAC tables, as the original does for
  Yosys, because Gowin cannot synthesise `real` variables either.
- **`sid_filter.sv`**: `$acos(-1.0)` and `$pow(2.0, ...)`, real literals,
  which Gowin requires for those functions.
- **`sid_api.sv`**: a `model_sel` input chooses the model of each SID
  (6581 or 8580) at run time, and SID 2 is selected by `cs.a5`, as at $D420.

## Simulation

Icarus Verilog cannot parse this SystemVerilog, so the SoC's simulations use
`../../sim/sid_api_stub.v`, which has the same ports and takes writes the same
way but makes no sound. reDIP SID's own simulation uses Verilator.
