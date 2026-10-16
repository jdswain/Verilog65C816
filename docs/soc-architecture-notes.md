# SoC architecture notes (65C816 core)

> **Historical.** This is the early design discussion, kept for its
> reasoning. Most of it has since been built: the cache, the burst SDRAM
> controller, the peripheral bridge (`external_bus.v`) and the display as an
> arbiter client. Some of it has been overtaken. The argument against split
> I/D caches no longer holds, because self-modifying code is no longer a
> constraint (see "Next" in `fpga/README.md`), and the 16-bit CPU data path
> was measured and deprioritised. For the SoC as built see `fpga/README.md`;
> for the target board see `Hardware.md`.

Design discussion capturing the direction for building an SoC around this core.

## The split bus dissolves the protocol debate

RD/WR vs 6800 vs 68000 only conflicts if one bus does two incompatible jobs.
Split it and each side gets the right protocol:

```
   CPU core (keep its clean sync bus: addr/wdata/rdata/we/vld/rdy + VPA/VDA/VPB/MLB)
                    |
         +----------+-----------+   address decode
         v                      v
  +-----------------+    +--------------------+
  | unified cache   |    | peripheral bridge  |
  | + SDRAM ctrl    |    | 8-bit, per-CS waits|
  | (wide, bursts)  |    +--+----+----+----+--+
  +--------+--------+       VIA  SCC  SCSI  SPI/RTC
           ^  ^
         DMA  video-fetch (arbitrated masters)
```

**Keep the CPU core bus-protocol-agnostic.** Its current synchronous interface
is a good internal fabric. RD̄/WR̄ vs PHI2/R-W̄ becomes a *peripheral-bridge*
concern, not a core change. So the "fix bus to R/W + PHI2" TODO is really
"build a peripheral bridge" — the core stays as-is.

## Protocol choices

- **Memory side:** don't expose Intel-style RD/WR here; it talks to an SDRAM
  controller whose native command/DQM interface is the real protocol. Width
  lives behind the cache ("as wide as we want").
- **Peripheral side:** 8-bit, generic **RD̄/WR̄ + chip-select + per-CS
  programmable wait states** (lingua franca, easiest to glue). Wrinkles: the
  65C22 wants Φ2/R-W̄; the NMOS Z8530 SCC has recovery-time/setup quirks.
  - Implement peripherals as **soft cores on the internal peripheral bus**
    where possible (soft VIA, soft SPI master for the RTC — no external RTC
    chip needed). No glue, no timing pain.
  - Only generate "classic" pin timing for chips you must use externally
    (real SCC, real 5380 SCSI); the bridge handles per-CS timing/waits.

## The 68000-bus idea: take one part, leave the rest

Reject the 68000 *peripheral* model — its "ecosystem" is mostly 6800-bus parts
accessed via the 68000's E/VMA/VPA synchronous-6800 cycle, so you'd adopt async
DTACK + function codes for no peripheral payoff. **The one good 68000 idea is
UDS̄/LDS̄ — byte strobes on a 16-bit data bus — and it belongs to the *memory*
side.** Steal exactly that. (Endianness: 65xx is little-endian, 68000
big-endian; byte-lane mapping must follow 65xx — don't import 68000 lane
conventions.)

## Cache: unified, with VPA-driven prefetch

This is where VPA/VDA pay off and the **single highest-value addition** once
SDRAM-backed — random SDRAM latency otherwise stalls every fetch and the wide
bus buys nothing.

- **Unified cache, not split I/D.** The 65xx world is full of self-modifying
  code and direct-page trickery; a separate I-cache creates a coherency
  headache (stale I-line after a D-write) not worth it.
- Use **VPA only to drive a prefetch queue** (program fetches are sequential,
  read-only — cheap and effective behind a wide SDRAM burst). VDA data accesses
  go through the same coherent cache.
- **MLB** is the "don't let DMA steal the bus mid-RMW" signal for the arbiter —
  earns its keep the moment there's a second master.

## DMA + video are arbiter clients; video is a bandwidth question

Both sit on the memory arbiter. Budget **video bandwidth/contention**:
640×480×8@60 ≈ 18 MB/s of guaranteed refetch competing with CPU+DMA. Give video
a line-buffer FIFO fed by bursts (amortizes SDRAM row activations) + high
arbiter priority, or a second SDRAM port. The CPU cache keeps video contention
from clobbering CPU throughput — another reason to do the cache early.

Add a small **interrupt controller**: SCC + SCSI + VIA + RTC all raise IRQ but
the 816 has one IRQ line — you need aggregation/masking/status (tiny vectored or
polled PIC) or you'll poll everything in the ISR.

## Pipelining vs simpler wins

Mitsubishi's 7700/7900 pipelined because they were MCUs with on-chip fast
memory and no cache — overlapping multi-cycle decode was their only lever. Here
the latency problem is **SDRAM, not decode**, and the core already runs fewer
cycles than the real chip with no phantom cycles.

Throughput levers, best ROI first:

1. **Unified cache + VPA prefetch queue** — hides SDRAM latency; without it
   nothing else matters. A prefetch queue *is* fetch/execute overlap, so it
   gives most of what a "pipeline" would.
2. **16-bit memory data path with byte enables** — collapse `S_RDL+S_RDH` and
   operand low+high into single word accesses. The core already holds 16-bit
   values; the change is the access-FSM issuing aligned word reads/writes and
   handling odd-address splits. Cheap behind a 16-bit-wide cache line.
3. **True pipelining (overlap decode N+1 with execute N)** — last, maybe never.
   Variable-length instructions, M/X-width-dependent operand sizes, and SMC
   hazards make it fiddly for modest gain once 1+2 are done.

## Net recommendation / ordering

1. Commit to the split bus; keep the CPU core interface as the internal fabric.
2. Build **unified cache + SDRAM controller + VPA-driven prefetch** next.
3. Add the **8-bit peripheral bridge** (RD̄/WR̄ + per-CS waits), peripherals as
   soft cores where possible; plus a small **interrupt controller**.
4. DMA + video as arbiter clients; budget video bandwidth with a FIFO.
5. Then the **16-bit memory path** (UDS/LDS-style byte enables — the one bit
   worth borrowing from the 68000), inside the core's access FSM.
6. Treat real pipelining as optional/last.

TODO reframe: "fix bus to R/W + PHI2" is a *peripheral-bridge* task, not a core
change — leaving the core bus clean is what lets one CPU serve VIA-style,
Intel-style, and SCC-style chips without recompiling the core. The only
core-level bus work genuinely justified is the 16-bit data path.
