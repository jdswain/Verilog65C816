//============================================================================
// cpu_65c816.v -- WDC 65C816 compatible CPU core
//
// Goals: functional compatibility, NOT cycle accuracy. Every bus cycle does
// useful work: there are no dummy/phantom reads or writes (unlike the real
// chip / 6502). Most instructions complete in fewer cycles than the real
// part. Implied register ops (TAX, INX, CLC, XCE, ...) take a single cycle:
// latched at their fetch, executed during the next opcode's.
//
// Nothing computes on the read data in the cycle it arrives, and the bus
// address is a mux of registers. A read's operand is latched and its execute
// runs in the next cycle (xp), overlapped with the next opcode fetch, as is an
// implied opcode's (lp); an RMW's result is formed in its write cycle. Only a
// pull fetched behind such an execute, and an interrupt, wait a cycle for it.
//
// Instruction bytes come from an 8-byte queue, never straight off the bus.
// The queue fills a 32-bit word at a time (rdata32) in cycles the core does
// not use the bus. An instruction takes two cycles from its head, the opcode
// and then all its operand bytes at once (S_OPS); a jump empties it. Self-modifying code is not supported:
// a store to bytes already queued does not change them.
//
// Bus protocol (simple synchronous SRAM-style):
//   - When `vld` is high a bus cycle is in progress at `addr`.
//   - Read  (we=0): memory must drive `rdata` combinationally in the same
//     cycle (async read); the core samples it on the rising clock edge when
//     rdy=1. For synchronous memories, hold `rdy` low for one cycle. A
//     memory that can also drive the whole aligned word on `rdata32` raises
//     `r32`; the instruction queue then takes all of it (else one byte).
//     Queue fills are flagged VPA=1, VDA=0.
//   - Write (we=1): `addr`/`wdata` are valid; the system commits the write
//     on the rising edge when rdy=1.
//   - `rdy` low holds the bus cycle (wait states). A state that does not
//     use the bus keeps running while a queue fill waits.
//
// Interrupts: RES (rst_n), NMI (falling edge), IRQ (level). ABORT is not
// implemented.
//
// Known simplifications (documented deviations from the real chip):
//   - No cycle accuracy; bus traffic differs from the real part.
//   - Emulation-mode page-wrap quirks are not modeled: direct-page pointer
//     fetches use full 16-bit wrap in bank 0 (not page wrap when DL=0).
//   - Indexed data accesses always use 24-bit address arithmetic (they can
//     cross banks even in emulation mode).
//   - The V flag in decimal mode is computed as for binary arithmetic.
//   - VPA/VDA/VPB/MLB status outputs and ABORT are not provided.
//
// Extension: banked direct page and stack (docs/BankedDP.md). WDM $B1 sets
// the mode, WDM $B0 clears it (reset clears it; other WDMs stay no-ops). In
// native mode with the mode set, D is a page number: the direct page is at
// {D, $00} and the stack at {DH, S}, so both leave bank 0 together.
//============================================================================

`default_nettype none

module cpu_65c816 (
    input  wire        clk,
    input  wire        rst_n,
    // bus
    output reg  [23:0] addr,
    output reg  [7:0]  wdata,
    input  wire [7:0]  rdata,
    input  wire [31:0] rdata32, // the aligned word holding addr, when r32
    input  wire        r32,     // this read returns the whole word (rdata32)
    output reg         we,      // 1 = write cycle
    output reg         vld,     // bus cycle valid
    input  wire        rdy,     // memory ready (wait-state when low)
    // interrupts
    input  wire        irq_n,
    input  wire        nmi_n,
    input  wire        abort_n, // abort current instruction (active low)
    // bus-cycle classification (like the W65C816 status pins)
    output reg         vpa,     // valid program address (opcode/operand fetch)
    output reg         vda,     // valid data address (data read/write)
    output reg         vpb_n,   // vector pull, active low
    output reg         mlb_n,   // memory lock (RMW), active low
    // status
    output wire        e_flag,  // emulation mode
    output wire        m_flag,
    output wire        x_flag,
    output wire        stopped  // STP executed (until reset)
);

    //------------------------------------------------------------------
    // Architectural registers
    //------------------------------------------------------------------
    reg [15:0] A;        // C accumulator (B = A[15:8])
    reg [15:0] X, Y;     // index registers (high byte forced 0 when x=1)
    reg [15:0] S;        // stack pointer (high byte forced 01 when E=1)
    reg [15:0] D;        // direct page register
    reg [15:0] PC;
    reg [7:0]  DBR, PBR;
    reg fC, fZ, fI, fD, fX, fM, fV, fN, fE;
    reg xb;              // banked direct page and stack (WDM $B1 / $B0)

    wire m16 = ~fE & ~fM;     // 16-bit accumulator/memory
    wire x16 = ~fE & ~fX;     // 16-bit index registers

    assign e_flag  = fE;
    assign m_flag  = fM;
    assign x_flag  = fX;

    //------------------------------------------------------------------
    // FSM state
    //------------------------------------------------------------------
    localparam [4:0]
        S_FETCH = 5'd0,   // opcode fetch (+ folded implied execute)
        S_OPS   = 5'd1,   // the operand bytes, all at once
        S_PTRL  = 5'd4,   // indirect pointer low
        S_PTRH  = 5'd5,   // indirect pointer high
        S_PTRB  = 5'd6,   // indirect pointer bank
        S_RDL   = 5'd7,   // data read low  (execute folds here for 8-bit)
        S_RDH   = 5'd8,   // data read high (execute folds here for 16-bit)
        S_WRL   = 5'd9,   // store write low
        S_WRH   = 5'd10,  // store write high
        S_WBL   = 5'd11,  // RMW write-back low
        S_WBH   = 5'd12,  // RMW write-back high
        S_PUSH  = 5'd13,  // stack push (multi-byte)
        S_PULL  = 5'd14,  // stack pull (multi-byte)
        S_VECL  = 5'd15,  // vector fetch low
        S_VECH  = 5'd16,  // vector fetch high
        S_MVR   = 5'd17,  // block move read
        S_MVW   = 5'd18,  // block move write
        S_WAI   = 5'd19,  // waiting for interrupt
        S_STP   = 5'd20,  // stopped
        S_IMP   = 5'd21;  // push / WAI / STP setup

    reg [4:0] state;
    assign stopped = (state == S_STP);

    //------------------------------------------------------------------
    // Addressing modes / classes / operations (from decode)
    //------------------------------------------------------------------
    localparam [4:0]
        MD_NON=5'd0,  MD_IMM=5'd1,  MD_DP =5'd2,  MD_DPX=5'd3,  MD_DPY=5'd4,
        MD_ABS=5'd5,  MD_ABX=5'd6,  MD_ABY=5'd7,  MD_ABL=5'd8,  MD_ALX=5'd9,
        MD_IDX=5'd10, MD_IDP=5'd11, MD_IDY=5'd12, MD_IDL=5'd13, MD_ILY=5'd14,
        MD_SR =5'd15, MD_SRY=5'd16, MD_REL=5'd17, MD_RLL=5'd18,
        MD_IAB=5'd19, MD_IAX=5'd20, MD_IAL=5'd21;

    localparam [2:0]
        CL_SPC=3'd0, CL_RD=3'd1, CL_WR=3'd2, CL_MW=3'd3, CL_JMP=3'd4,
        CL_JSR=3'd5;

    localparam [4:0]
        OP_ORA=5'd0,  OP_AND=5'd1,  OP_EOR=5'd2,  OP_ADC=5'd3,  OP_SBC=5'd4,
        OP_CMP=5'd5,  OP_LDA=5'd6,  OP_BIT=5'd7,  OP_LDX=5'd8,  OP_LDY=5'd9,
        OP_CPX=5'd10, OP_CPY=5'd11, OP_STA=5'd12, OP_STX=5'd13, OP_STY=5'd14,
        OP_STZ=5'd15, OP_ASL=5'd16, OP_ROL=5'd17, OP_LSR=5'd18, OP_ROR=5'd19,
        OP_INC=5'd20, OP_DEC=5'd21, OP_TSB=5'd22, OP_TRB=5'd23, OP_REP=5'd24,
        OP_SEP=5'd25, OP_NOP=5'd26;

    //------------------------------------------------------------------
    // Working registers
    //------------------------------------------------------------------
    reg [7:0]  IR;
    reg [7:0]  tlo, tmid;     // operand / pointer byte accumulators
    reg [15:0] tptr;          // indirect pointer address
    reg [7:0]  ptr_bank;      // bank for pointer fetches
    reg [23:0] taddr;         // effective data address
    reg        wrap16;        // effective addr +1 wraps within bank (dp/stack)
    reg [15:0] tdata;         // RMW result / block-move byte
    reg [31:0] push_q;        // push queue, MSB first
    reg [2:0]  push_n;
    reg        stk16;         // new 16-bit stack op (PEA/PEI/PER/PHD/PLD):
                              // S crosses pages in emulation, SH restored after
    reg [1:0]  post_push;     // routing after the last push
    reg [1:0]  pull_idx;
    reg [15:0] vec;           // interrupt vector address (bank 0)
    reg [23:0] taddr_alt;     // the other byte's address of a 16-bit access
    reg [23:0] pa;            // the next pull's address
    // Deferred execute: a read-class instruction's operand is latched as it
    // arrives (xm) and executed in the next cycle, the following opcode fetch,
    // so no ALU sits behind the read data. An opcode that is itself executed
    // in the fetch cycle, or an interrupt, waits a cycle for it.
    reg        xp;            // an execute is pending, of xm
    reg        lp;            // an implied opcode's execute is pending (IR)
    reg [15:0] xm;
    reg        snap_late;     // the ABORT snapshot's registers, a cycle late

    // Instruction queue. Opcode and operand bytes come from here, never
    // from the bus: a fetcher fills it a word at a time in the cycles the
    // core does not use the bus, and the core takes bytes from its head.
    // q[7:0] is the byte at PC; fa = PC + qn is the next byte to fetch.
    // A jump empties it (and drops a fetch in flight). Self-modifying code
    // is not supported: bytes already queued are not refetched.
    reg [63:0] q;
    reg [3:0]  qn;            // bytes queued, 0-8
    reg [15:0] fa;            // offset in PBR of the next byte to fetch
    reg [23:0] faddr;         // the fetch in flight's address
    reg        fbusy;         // a fetch holds the bus until rdy
    reg        fdrop;         // ... and its bytes are stale (a jump since)
    // per-cycle flags from the state machine to the queue logic
    reg [1:0]  take;          // bytes taken from the head
    reg        jmp;           // PC written out of sequence: empty the queue
    reg [15:0] jpc;
    reg [7:0]  jbank;         // and the bank to fetch from
    wire [7:0] qb = q[7:0];

    localparam [1:0] PP_FETCH=2'd0, PP_VEC=2'd1, PP_PTR=2'd2;

    // interrupt synchronizers / NMI edge detect. irq2 and nmi_pend change
    // only as a bus cycle ends (step): S_FETCH drops vld for an interrupt,
    // and an opcode fetch that is waiting for rdy must not be abandoned --
    // the memory may finish it anyway and its rdy would end the next access.
    reg  irq1, irq2, nmi1, nmi2, nmi_pend, nmi_seen;
    reg  ab;                      // synchronized ABORT input
    wire intr = nmi_pend | (~irq2 & ~fI);

    //------------------------------------------------------------------
    // ABORT support. The aborted instruction must commit nothing: a
    // snapshot of the architectural state taken at the opcode fetch is
    // restored, all writes during the instruction are suppressed, and the
    // core then vectors through the ABORT vector with the *opcode* address
    // pushed (so RTI retries the instruction).
    //------------------------------------------------------------------
    reg        abort_pend;       // an abort is pending for the running instr
    reg [15:0] sA, sX, sY, sS, sD, sPC;
    reg [7:0]  sDBR, sPBR;
    reg        sxb;
    reg        sfN, sfV, sfM, sfX, sfD, sfI, sfZ, sfC, sfE;

    // ABORT may be recognized during any instruction-execution state, but not
    // during an interrupt/abort entry (push + vector fetch) or while halted.
    wire abortable = ~(((state == S_PUSH) & (post_push == PP_VEC)) |
                       (state == S_VECL) | (state == S_VECH) |
                       (state == S_STP)  | (state == S_WAI));
    wire abrt = ~ab & abortable;   // abort recognized this cycle

    //------------------------------------------------------------------
    // Decode (combinational, from IR)
    //------------------------------------------------------------------
    // Instruction decode.
    //
    // This is a REGISTERED decode: the 256-way case is a function applied to
    // the opcode as it arrives, and the result is latched alongside IR. Left
    // combinational off IR it sat between the instruction register and the
    // execute logic, adding a 256-way decode to every execute path.
    reg [4:0] d_mode;
    reg [2:0] d_cls;
    reg [4:0] d_op;
    reg [1:0] d_len;          // operand bytes (an immediate's, 8-bit)

    function [12:0] dec(input [7:0] op);
        reg [4:0] dm;
        reg [2:0] dc;
        reg [4:0] dp;
        begin
        dm = MD_NON; dc = CL_SPC; dp = OP_NOP;
        case (op)
        // 0x
        8'h00: ;                                                       // BRK (S_OPS special)
        8'h01: begin dm=MD_IDX; dc=CL_RD; dp=OP_ORA; end
        8'h02: ;                                                       // COP (S_OPS special)
        8'h03: begin dm=MD_SR;  dc=CL_RD; dp=OP_ORA; end
        8'h04: begin dm=MD_DP;  dc=CL_MW; dp=OP_TSB; end
        8'h05: begin dm=MD_DP;  dc=CL_RD; dp=OP_ORA; end
        8'h06: begin dm=MD_DP;  dc=CL_MW; dp=OP_ASL; end
        8'h07: begin dm=MD_IDL; dc=CL_RD; dp=OP_ORA; end
        8'h09: begin dm=MD_IMM; dc=CL_RD; dp=OP_ORA; end
        8'h0C: begin dm=MD_ABS; dc=CL_MW; dp=OP_TSB; end
        8'h0D: begin dm=MD_ABS; dc=CL_RD; dp=OP_ORA; end
        8'h0E: begin dm=MD_ABS; dc=CL_MW; dp=OP_ASL; end
        8'h0F: begin dm=MD_ABL; dc=CL_RD; dp=OP_ORA; end
        // 1x
        8'h10: dm=MD_REL;                                          // BPL
        8'h11: begin dm=MD_IDY; dc=CL_RD; dp=OP_ORA; end
        8'h12: begin dm=MD_IDP; dc=CL_RD; dp=OP_ORA; end
        8'h13: begin dm=MD_SRY; dc=CL_RD; dp=OP_ORA; end
        8'h14: begin dm=MD_DP;  dc=CL_MW; dp=OP_TRB; end
        8'h15: begin dm=MD_DPX; dc=CL_RD; dp=OP_ORA; end
        8'h16: begin dm=MD_DPX; dc=CL_MW; dp=OP_ASL; end
        8'h17: begin dm=MD_ILY; dc=CL_RD; dp=OP_ORA; end
        8'h19: begin dm=MD_ABY; dc=CL_RD; dp=OP_ORA; end
        8'h1C: begin dm=MD_ABS; dc=CL_MW; dp=OP_TRB; end
        8'h1D: begin dm=MD_ABX; dc=CL_RD; dp=OP_ORA; end
        8'h1E: begin dm=MD_ABX; dc=CL_MW; dp=OP_ASL; end
        8'h1F: begin dm=MD_ALX; dc=CL_RD; dp=OP_ORA; end
        // 2x
        8'h20: begin dm=MD_ABS; dc=CL_JSR; end                  // JSR abs
        8'h21: begin dm=MD_IDX; dc=CL_RD; dp=OP_AND; end
        8'h22: begin dm=MD_ABL; dc=CL_JSR; end                  // JSL long
        8'h23: begin dm=MD_SR;  dc=CL_RD; dp=OP_AND; end
        8'h24: begin dm=MD_DP;  dc=CL_RD; dp=OP_BIT; end
        8'h25: begin dm=MD_DP;  dc=CL_RD; dp=OP_AND; end
        8'h26: begin dm=MD_DP;  dc=CL_MW; dp=OP_ROL; end
        8'h27: begin dm=MD_IDL; dc=CL_RD; dp=OP_AND; end
        8'h29: begin dm=MD_IMM; dc=CL_RD; dp=OP_AND; end
        8'h2C: begin dm=MD_ABS; dc=CL_RD; dp=OP_BIT; end
        8'h2D: begin dm=MD_ABS; dc=CL_RD; dp=OP_AND; end
        8'h2E: begin dm=MD_ABS; dc=CL_MW; dp=OP_ROL; end
        8'h2F: begin dm=MD_ABL; dc=CL_RD; dp=OP_AND; end
        // 3x
        8'h30: dm=MD_REL;                                          // BMI
        8'h31: begin dm=MD_IDY; dc=CL_RD; dp=OP_AND; end
        8'h32: begin dm=MD_IDP; dc=CL_RD; dp=OP_AND; end
        8'h33: begin dm=MD_SRY; dc=CL_RD; dp=OP_AND; end
        8'h34: begin dm=MD_DPX; dc=CL_RD; dp=OP_BIT; end
        8'h35: begin dm=MD_DPX; dc=CL_RD; dp=OP_AND; end
        8'h36: begin dm=MD_DPX; dc=CL_MW; dp=OP_ROL; end
        8'h37: begin dm=MD_ILY; dc=CL_RD; dp=OP_AND; end
        8'h39: begin dm=MD_ABY; dc=CL_RD; dp=OP_AND; end
        8'h3C: begin dm=MD_ABX; dc=CL_RD; dp=OP_BIT; end
        8'h3D: begin dm=MD_ABX; dc=CL_RD; dp=OP_AND; end
        8'h3E: begin dm=MD_ABX; dc=CL_MW; dp=OP_ROL; end
        8'h3F: begin dm=MD_ALX; dc=CL_RD; dp=OP_AND; end
        // 4x
        8'h41: begin dm=MD_IDX; dc=CL_RD; dp=OP_EOR; end
        8'h42: begin dm=MD_IMM; dc=CL_RD; dp=OP_NOP; end      // WDM
        8'h43: begin dm=MD_SR;  dc=CL_RD; dp=OP_EOR; end
        8'h44: ;                                                       // MVP (special)
        8'h45: begin dm=MD_DP;  dc=CL_RD; dp=OP_EOR; end
        8'h46: begin dm=MD_DP;  dc=CL_MW; dp=OP_LSR; end
        8'h47: begin dm=MD_IDL; dc=CL_RD; dp=OP_EOR; end
        8'h49: begin dm=MD_IMM; dc=CL_RD; dp=OP_EOR; end
        8'h4C: begin dm=MD_ABS; dc=CL_JMP; end                  // JMP abs
        8'h4D: begin dm=MD_ABS; dc=CL_RD; dp=OP_EOR; end
        8'h4E: begin dm=MD_ABS; dc=CL_MW; dp=OP_LSR; end
        8'h4F: begin dm=MD_ABL; dc=CL_RD; dp=OP_EOR; end
        // 5x
        8'h50: dm=MD_REL;                                          // BVC
        8'h51: begin dm=MD_IDY; dc=CL_RD; dp=OP_EOR; end
        8'h52: begin dm=MD_IDP; dc=CL_RD; dp=OP_EOR; end
        8'h53: begin dm=MD_SRY; dc=CL_RD; dp=OP_EOR; end
        8'h54: ;                                                       // MVN (special)
        8'h55: begin dm=MD_DPX; dc=CL_RD; dp=OP_EOR; end
        8'h56: begin dm=MD_DPX; dc=CL_MW; dp=OP_LSR; end
        8'h57: begin dm=MD_ILY; dc=CL_RD; dp=OP_EOR; end
        8'h59: begin dm=MD_ABY; dc=CL_RD; dp=OP_EOR; end
        8'h5C: begin dm=MD_ABL; dc=CL_JMP; end                  // JML long
        8'h5D: begin dm=MD_ABX; dc=CL_RD; dp=OP_EOR; end
        8'h5E: begin dm=MD_ABX; dc=CL_MW; dp=OP_LSR; end
        8'h5F: begin dm=MD_ALX; dc=CL_RD; dp=OP_EOR; end
        // 6x
        8'h61: begin dm=MD_IDX; dc=CL_RD; dp=OP_ADC; end
        8'h62: dm=MD_RLL;                                          // PER (special)
        8'h63: begin dm=MD_SR;  dc=CL_RD; dp=OP_ADC; end
        8'h64: begin dm=MD_DP;  dc=CL_WR; dp=OP_STZ; end
        8'h65: begin dm=MD_DP;  dc=CL_RD; dp=OP_ADC; end
        8'h66: begin dm=MD_DP;  dc=CL_MW; dp=OP_ROR; end
        8'h67: begin dm=MD_IDL; dc=CL_RD; dp=OP_ADC; end
        8'h69: begin dm=MD_IMM; dc=CL_RD; dp=OP_ADC; end
        8'h6C: begin dm=MD_IAB; dc=CL_JMP; end                  // JMP (abs)
        8'h6D: begin dm=MD_ABS; dc=CL_RD; dp=OP_ADC; end
        8'h6E: begin dm=MD_ABS; dc=CL_MW; dp=OP_ROR; end
        8'h6F: begin dm=MD_ABL; dc=CL_RD; dp=OP_ADC; end
        // 7x
        8'h70: dm=MD_REL;                                          // BVS
        8'h71: begin dm=MD_IDY; dc=CL_RD; dp=OP_ADC; end
        8'h72: begin dm=MD_IDP; dc=CL_RD; dp=OP_ADC; end
        8'h73: begin dm=MD_SRY; dc=CL_RD; dp=OP_ADC; end
        8'h74: begin dm=MD_DPX; dc=CL_WR; dp=OP_STZ; end
        8'h75: begin dm=MD_DPX; dc=CL_RD; dp=OP_ADC; end
        8'h76: begin dm=MD_DPX; dc=CL_MW; dp=OP_ROR; end
        8'h77: begin dm=MD_ILY; dc=CL_RD; dp=OP_ADC; end
        8'h79: begin dm=MD_ABY; dc=CL_RD; dp=OP_ADC; end
        8'h7C: begin dm=MD_IAX; dc=CL_JMP; end                  // JMP (abs,X)
        8'h7D: begin dm=MD_ABX; dc=CL_RD; dp=OP_ADC; end
        8'h7E: begin dm=MD_ABX; dc=CL_MW; dp=OP_ROR; end
        8'h7F: begin dm=MD_ALX; dc=CL_RD; dp=OP_ADC; end
        // 8x
        8'h80: dm=MD_REL;                                          // BRA
        8'h81: begin dm=MD_IDX; dc=CL_WR; dp=OP_STA; end
        8'h82: dm=MD_RLL;                                          // BRL
        8'h83: begin dm=MD_SR;  dc=CL_WR; dp=OP_STA; end
        8'h84: begin dm=MD_DP;  dc=CL_WR; dp=OP_STY; end
        8'h85: begin dm=MD_DP;  dc=CL_WR; dp=OP_STA; end
        8'h86: begin dm=MD_DP;  dc=CL_WR; dp=OP_STX; end
        8'h87: begin dm=MD_IDL; dc=CL_WR; dp=OP_STA; end
        8'h89: begin dm=MD_IMM; dc=CL_RD; dp=OP_BIT; end      // BIT # (Z only)
        8'h8C: begin dm=MD_ABS; dc=CL_WR; dp=OP_STY; end
        8'h8D: begin dm=MD_ABS; dc=CL_WR; dp=OP_STA; end
        8'h8E: begin dm=MD_ABS; dc=CL_WR; dp=OP_STX; end
        8'h8F: begin dm=MD_ABL; dc=CL_WR; dp=OP_STA; end
        // 9x
        8'h90: dm=MD_REL;                                          // BCC
        8'h91: begin dm=MD_IDY; dc=CL_WR; dp=OP_STA; end
        8'h92: begin dm=MD_IDP; dc=CL_WR; dp=OP_STA; end
        8'h93: begin dm=MD_SRY; dc=CL_WR; dp=OP_STA; end
        8'h94: begin dm=MD_DPX; dc=CL_WR; dp=OP_STY; end
        8'h95: begin dm=MD_DPX; dc=CL_WR; dp=OP_STA; end
        8'h96: begin dm=MD_DPY; dc=CL_WR; dp=OP_STX; end
        8'h97: begin dm=MD_ILY; dc=CL_WR; dp=OP_STA; end
        8'h99: begin dm=MD_ABY; dc=CL_WR; dp=OP_STA; end
        8'h9C: begin dm=MD_ABS; dc=CL_WR; dp=OP_STZ; end
        8'h9D: begin dm=MD_ABX; dc=CL_WR; dp=OP_STA; end
        8'h9E: begin dm=MD_ABX; dc=CL_WR; dp=OP_STZ; end
        8'h9F: begin dm=MD_ALX; dc=CL_WR; dp=OP_STA; end
        // Ax
        8'hA0: begin dm=MD_IMM; dc=CL_RD; dp=OP_LDY; end
        8'hA1: begin dm=MD_IDX; dc=CL_RD; dp=OP_LDA; end
        8'hA2: begin dm=MD_IMM; dc=CL_RD; dp=OP_LDX; end
        8'hA3: begin dm=MD_SR;  dc=CL_RD; dp=OP_LDA; end
        8'hA4: begin dm=MD_DP;  dc=CL_RD; dp=OP_LDY; end
        8'hA5: begin dm=MD_DP;  dc=CL_RD; dp=OP_LDA; end
        8'hA6: begin dm=MD_DP;  dc=CL_RD; dp=OP_LDX; end
        8'hA7: begin dm=MD_IDL; dc=CL_RD; dp=OP_LDA; end
        8'hA9: begin dm=MD_IMM; dc=CL_RD; dp=OP_LDA; end
        8'hAC: begin dm=MD_ABS; dc=CL_RD; dp=OP_LDY; end
        8'hAD: begin dm=MD_ABS; dc=CL_RD; dp=OP_LDA; end
        8'hAE: begin dm=MD_ABS; dc=CL_RD; dp=OP_LDX; end
        8'hAF: begin dm=MD_ABL; dc=CL_RD; dp=OP_LDA; end
        // Bx
        8'hB0: dm=MD_REL;                                          // BCS
        8'hB1: begin dm=MD_IDY; dc=CL_RD; dp=OP_LDA; end
        8'hB2: begin dm=MD_IDP; dc=CL_RD; dp=OP_LDA; end
        8'hB3: begin dm=MD_SRY; dc=CL_RD; dp=OP_LDA; end
        8'hB4: begin dm=MD_DPX; dc=CL_RD; dp=OP_LDY; end
        8'hB5: begin dm=MD_DPX; dc=CL_RD; dp=OP_LDA; end
        8'hB6: begin dm=MD_DPY; dc=CL_RD; dp=OP_LDX; end
        8'hB7: begin dm=MD_ILY; dc=CL_RD; dp=OP_LDA; end
        8'hB9: begin dm=MD_ABY; dc=CL_RD; dp=OP_LDA; end
        8'hBC: begin dm=MD_ABX; dc=CL_RD; dp=OP_LDY; end
        8'hBD: begin dm=MD_ABX; dc=CL_RD; dp=OP_LDA; end
        8'hBE: begin dm=MD_ABY; dc=CL_RD; dp=OP_LDX; end
        8'hBF: begin dm=MD_ALX; dc=CL_RD; dp=OP_LDA; end
        // Cx
        8'hC0: begin dm=MD_IMM; dc=CL_RD; dp=OP_CPY; end
        8'hC1: begin dm=MD_IDX; dc=CL_RD; dp=OP_CMP; end
        8'hC2: begin dm=MD_IMM; dc=CL_RD; dp=OP_REP; end
        8'hC3: begin dm=MD_SR;  dc=CL_RD; dp=OP_CMP; end
        8'hC4: begin dm=MD_DP;  dc=CL_RD; dp=OP_CPY; end
        8'hC5: begin dm=MD_DP;  dc=CL_RD; dp=OP_CMP; end
        8'hC6: begin dm=MD_DP;  dc=CL_MW; dp=OP_DEC; end
        8'hC7: begin dm=MD_IDL; dc=CL_RD; dp=OP_CMP; end
        8'hC9: begin dm=MD_IMM; dc=CL_RD; dp=OP_CMP; end
        8'hCC: begin dm=MD_ABS; dc=CL_RD; dp=OP_CPY; end
        8'hCD: begin dm=MD_ABS; dc=CL_RD; dp=OP_CMP; end
        8'hCE: begin dm=MD_ABS; dc=CL_MW; dp=OP_DEC; end
        8'hCF: begin dm=MD_ABL; dc=CL_RD; dp=OP_CMP; end
        // Dx
        8'hD0: dm=MD_REL;                                          // BNE
        8'hD1: begin dm=MD_IDY; dc=CL_RD; dp=OP_CMP; end
        8'hD2: begin dm=MD_IDP; dc=CL_RD; dp=OP_CMP; end
        8'hD3: begin dm=MD_SRY; dc=CL_RD; dp=OP_CMP; end
        8'hD4: ;                                                       // PEI (special)
        8'hD5: begin dm=MD_DPX; dc=CL_RD; dp=OP_CMP; end
        8'hD6: begin dm=MD_DPX; dc=CL_MW; dp=OP_DEC; end
        8'hD7: begin dm=MD_ILY; dc=CL_RD; dp=OP_CMP; end
        8'hD9: begin dm=MD_ABY; dc=CL_RD; dp=OP_CMP; end
        8'hDC: begin dm=MD_IAL; dc=CL_JMP; end                  // JML [abs]
        8'hDD: begin dm=MD_ABX; dc=CL_RD; dp=OP_CMP; end
        8'hDE: begin dm=MD_ABX; dc=CL_MW; dp=OP_DEC; end
        8'hDF: begin dm=MD_ALX; dc=CL_RD; dp=OP_CMP; end
        // Ex
        8'hE0: begin dm=MD_IMM; dc=CL_RD; dp=OP_CPX; end
        8'hE1: begin dm=MD_IDX; dc=CL_RD; dp=OP_SBC; end
        8'hE2: begin dm=MD_IMM; dc=CL_RD; dp=OP_SEP; end
        8'hE3: begin dm=MD_SR;  dc=CL_RD; dp=OP_SBC; end
        8'hE4: begin dm=MD_DP;  dc=CL_RD; dp=OP_CPX; end
        8'hE5: begin dm=MD_DP;  dc=CL_RD; dp=OP_SBC; end
        8'hE6: begin dm=MD_DP;  dc=CL_MW; dp=OP_INC; end
        8'hE7: begin dm=MD_IDL; dc=CL_RD; dp=OP_SBC; end
        8'hE9: begin dm=MD_IMM; dc=CL_RD; dp=OP_SBC; end
        8'hEC: begin dm=MD_ABS; dc=CL_RD; dp=OP_CPX; end
        8'hED: begin dm=MD_ABS; dc=CL_RD; dp=OP_SBC; end
        8'hEE: begin dm=MD_ABS; dc=CL_MW; dp=OP_INC; end
        8'hEF: begin dm=MD_ABL; dc=CL_RD; dp=OP_SBC; end
        // Fx
        8'hF0: dm=MD_REL;                                          // BEQ
        8'hF1: begin dm=MD_IDY; dc=CL_RD; dp=OP_SBC; end
        8'hF2: begin dm=MD_IDP; dc=CL_RD; dp=OP_SBC; end
        8'hF3: begin dm=MD_SRY; dc=CL_RD; dp=OP_SBC; end
        8'hF4: ;                                                       // PEA (special)
        8'hF5: begin dm=MD_DPX; dc=CL_RD; dp=OP_SBC; end
        8'hF6: begin dm=MD_DPX; dc=CL_MW; dp=OP_INC; end
        8'hF7: begin dm=MD_ILY; dc=CL_RD; dp=OP_SBC; end
        8'hF9: begin dm=MD_ABY; dc=CL_RD; dp=OP_SBC; end
        8'hFC: begin dm=MD_IAX; dc=CL_JSR; end                  // JSR (abs,X)
        8'hFD: begin dm=MD_ABX; dc=CL_RD; dp=OP_SBC; end
        8'hFE: begin dm=MD_ABX; dc=CL_MW; dp=OP_INC; end
        8'hFF: begin dm=MD_ALX; dc=CL_RD; dp=OP_SBC; end
        default: ;   // remaining opcodes are handled entirely in S_FETCH
        endcase
        dec = {dm, dc, dp};
        end
    endfunction

    // Decode the byte arriving on the bus, ONCE. A Verilog function is inlined
    // at every call site, so calling dec(rdata) from each place that loads IR
    // would build a separate 256-way decoder each time.
    wire [12:0] dec_in = dec(qb);

    // The operand bytes the opcode being fetched takes (an immediate's
    // second byte, which hangs on m or x, is added in S_OPS).
    reg [1:0] len_in;
    always @* begin
        case (qb)
        8'h44, 8'h54, 8'hF4: len_in = 2'd2;             // MVP/MVN, PEA
        8'h00, 8'h02, 8'hD4: len_in = 2'd1;             // BRK, COP, PEI
        default: case (dec_in[12:8])
            MD_ABS, MD_ABX, MD_ABY, MD_RLL,
            MD_IAB, MD_IAX, MD_IAL: len_in = 2'd2;
            MD_ABL, MD_ALX:         len_in = 2'd3;
            default:                len_in = 2'd1;
            endcase
        endcase
    end

    // The opcode being fetched: implied (executed in the next cycle, lp),
    // a push, WAI or STP (S_IMP), or a pull (S_PULL).
    reg fetch_local, fetch_setup;
    always @* begin
        fetch_local = 1'b0; fetch_setup = 1'b0;
        case (qb)
        8'h18, 8'h38, 8'h58, 8'h78, 8'hB8, 8'hD8, 8'hF8, 8'hEA,
        8'h0A, 8'h2A, 8'h4A, 8'h6A, 8'h1A, 8'h3A,
        8'hAA, 8'hA8, 8'h8A, 8'h98, 8'hBA, 8'h9A, 8'h9B, 8'hBB,
        8'h1B, 8'h3B, 8'h5B, 8'h7B, 8'hE8, 8'hCA, 8'hC8, 8'h88,
        8'hEB, 8'hFB: fetch_local = 1'b1;
        8'h08, 8'h0B, 8'h48, 8'h4B, 8'h5A, 8'h8B, 8'hDA,
        8'hCB, 8'hDB: fetch_setup = 1'b1;
        default: ;
        endcase
    end
    wire fetch_pull = (qb == 8'h28) | (qb == 8'h2B) | (qb == 8'h68) |
                      (qb == 8'h7A) | (qb == 8'hAB) | (qb == 8'hFA) |
                      (qb == 8'h40) | (qb == 8'h60) | (qb == 8'h6B);

    // PLB, PLD and RTL use the 16-bit stack in emulation mode
    wire pull16 = (qb == 8'h2B) | (qb == 8'h6B) | (qb == 8'hAB);

    // operand width for reads/RMW; stores have their own
    wire op_xwide = (d_op==OP_LDX)||(d_op==OP_LDY)||(d_op==OP_CPX)||
                    (d_op==OP_CPY)||(d_op==OP_STX)||(d_op==OP_STY);
    wire op_8bit  = (d_op==OP_REP)||(d_op==OP_SEP)||(d_op==OP_NOP);
    wire rd16 = op_8bit ? 1'b0 : (op_xwide ? x16 : m16);   // read / RMW width
    wire st16 = op_xwide ? x16 : m16;                      // store width

    // store value
    reg [15:0] stval;
    always @* begin
        case (d_op)
        OP_STA:  stval = A;
        OP_STX:  stval = X;
        OP_STY:  stval = Y;
        default: stval = 16'h0000;   // STZ
        endcase
    end

    // width-masked register views
    wire [15:0] av = m16 ? A : {8'h00, A[7:0]};
    wire [15:0] xv = X;
    wire [15:0] yv = Y;

    // direct-page page-wrap active: emulation mode with DL = $00. Only the
    // base offset (dp + index) wraps within the page; the +1/+2 used to fetch
    // the upper bytes of a word/pointer are plain 16-bit increments and may
    // cross the page boundary.
    wire dpw = fE & (D[7:0] == 8'h00);

    // banked mode (native only): the direct page is at {D, $00} and the
    // stack at {DH, S}. dbase is the direct page's offset in its bank,
    // dbank the bank of the direct page, the stack and their pointers.
    wire        bk    = xb & ~fE;
    wire [15:0] dbase = bk ? {D[7:0], 8'h00} : D;
    wire [7:0]  dbank = bk ? D[15:8] : 8'h00;

    // common address helpers. The bus address is a mux of registers only:
    // the second byte's address of a word (taddr1), a pointer's next byte,
    // the next pull and the vector's high byte are all stepped into their
    // registers a cycle ahead, so no adder sits in front of the memory.
    wire [23:0] taddr1   = wrap16 ? {taddr[23:16], taddr[15:0] + 16'd1}
                                  : taddr + 24'd1;
    wire [23:0] sp_push  = (fE & ~stk16) ? {16'h0001, S[7:0]} : {dbank, S};
    wire [15:0] pcn      = PC + 16'd1;
    // S_OPS: the operand bytes and the address past the instruction
    wire [1:0]  olen     = d_len + {1'b0, (d_mode == MD_IMM) & rd16};
    wire [15:0] pce      = PC + {14'd0, olen};
    wire [7:0]  b1 = q[7:0], b2 = q[15:8], b3 = q[23:16];

    // P register byte (brkbit: value of bit4 in emulation mode)
    function [7:0] pbyte(input brkbit);
        pbyte = {fN, fV, fE ? 1'b1 : fM, fE ? brkbit : fX, fD, fI, fZ, fC};
    endfunction

    //------------------------------------------------------------------
    // Arithmetic helpers
    //------------------------------------------------------------------
    // decimal add: 4-nibble BCD chain. Returns {top, carry, sum[15:0]} where
    // `top` is bit 7 (8-bit) / bit 15 (16-bit) of the result BEFORE the final
    // high-nibble correction -- the 65C816 derives N and V from that point.
    function [17:0] dadd(input [15:0] a, input [15:0] b, input cin, input w);
        reg [4:0] n0, n1, n2, n3;
        reg c0, c1, c2, c3, top;
        begin
            n0 = a[3:0]  + b[3:0]  + cin; c0 = (n0 > 5'd9); if (c0) n0 = n0 + 5'd6;
            n1 = a[7:4]  + b[7:4]  + c0;
            if (!w) top = n1[3];
            c1 = (n1 > 5'd9); if (c1) n1 = n1 + 5'd6;
            n2 = a[11:8] + b[11:8] + c1;  c2 = (n2 > 5'd9); if (c2) n2 = n2 + 5'd6;
            n3 = a[15:12]+ b[15:12]+ c2;
            if (w) top = n3[3];
            c3 = (n3 > 5'd9); if (c3) n3 = n3 + 5'd6;
            dadd = w ? {top, c3, n3[3:0], n2[3:0], n1[3:0], n0[3:0]}
                     : {top, c1, 8'h00,            n1[3:0], n0[3:0]};
        end
    endfunction

    // decimal subtract: a - b, cin = inverted borrow; {carry, diff[15:0]}
    function [16:0] dsub(input [15:0] a, input [15:0] b, input cin, input w);
        reg [4:0] n0, n1, n2, n3;
        reg c0, c1, c2, c3;
        begin
            n0 = {1'b0, a[3:0]}  + {1'b0, ~b[3:0]}  + cin;
            c0 = n0[4]; if (!c0) n0 = n0 - 5'd6;
            n1 = {1'b0, a[7:4]}  + {1'b0, ~b[7:4]}  + c0;
            c1 = n1[4]; if (!c1) n1 = n1 - 5'd6;
            n2 = {1'b0, a[11:8]} + {1'b0, ~b[11:8]} + c1;
            c2 = n2[4]; if (!c2) n2 = n2 - 5'd6;
            n3 = {1'b0, a[15:12]}+ {1'b0, ~b[15:12]}+ c2;
            c3 = n3[4]; if (!c3) n3 = n3 - 5'd6;
            dsub = w ? {c3, n3[3:0], n2[3:0], n1[3:0], n0[3:0]}
                     : {c1, 8'h00,            n1[3:0], n0[3:0]};
        end
    endfunction

    //------------------------------------------------------------------
    // Register write helpers (set NZ per current width)
    //------------------------------------------------------------------
    task ld_a(input [15:0] v);
        begin
            if (m16) begin
                A <= v;          fN <= v[15]; fZ <= (v == 16'h0000);
            end else begin
                A[7:0] <= v[7:0]; fN <= v[7]; fZ <= (v[7:0] == 8'h00);
            end
        end
    endtask

    task ld_x(input [15:0] v);
        begin
            if (x16) begin
                X <= v;               fN <= v[15]; fZ <= (v == 16'h0000);
            end else begin
                X <= {8'h00, v[7:0]}; fN <= v[7];  fZ <= (v[7:0] == 8'h00);
            end
        end
    endtask

    task ld_y(input [15:0] v);
        begin
            if (x16) begin
                Y <= v;               fN <= v[15]; fZ <= (v == 16'h0000);
            end else begin
                Y <= {8'h00, v[7:0]}; fN <= v[7];  fZ <= (v[7:0] == 8'h00);
            end
        end
    endtask

    // write a value into P (PLP / RTI / REP / SEP)
    task set_p(input [7:0] v);
        begin
            fN <= v[7]; fV <= v[6]; fD <= v[3]; fI <= v[2];
            fZ <= v[1]; fC <= v[0];
            if (!fE) begin
                fM <= v[5]; fX <= v[4];
                if (v[4]) begin X[15:8] <= 8'h00; Y[15:8] <= 8'h00; end
            end
        end
    endtask

    // compare: reg - mem, sets NZC
    task cmp_flags(input [15:0] r, input [15:0] m, input w);
        reg [16:0] t;
        begin
            if (w) begin
                t = {1'b0, r} + {1'b0, ~m} + 17'd1;
                fC <= t[16]; fN <= t[15]; fZ <= (t[15:0] == 16'h0000);
            end else begin
                t = {9'b0, r[7:0]} + {9'b0, ~m[7:0] & 8'hFF} + 17'd1;
                fC <= t[8]; fN <= t[7]; fZ <= (t[7:0] == 8'h00);
            end
        end
    endtask

    task do_adc(input [15:0] m);
        reg [16:0] t;
        reg [17:0] da;
        begin
            if (fD) begin
                // Decimal: V comes from the pre-correction top bit (da[17]);
                // N and Z come from the corrected result; C from the decimal
                // carry.
                da = dadd(av, m, fC, m16);
                if (m16) fV <= ~(A[15] ^ m[15]) & (A[15] ^ da[17]);
                else     fV <= ~(A[7]  ^ m[7])  & (A[7]  ^ da[17]);
                fC <= da[16];
                ld_a(da[15:0]);
            end else if (m16) begin
                t = {1'b0, A} + {1'b0, m} + {16'd0, fC};
                fV <= ~(A[15] ^ m[15]) & (A[15] ^ t[15]);
                fC <= t[16];
                ld_a(t[15:0]);
            end else begin
                t = {9'd0, A[7:0]} + {9'd0, m[7:0]} + {16'd0, fC};
                fV <= ~(A[7] ^ m[7]) & (A[7] ^ t[7]);
                fC <= t[8];
                ld_a(t[15:0]);
            end
        end
    endtask

    task do_sbc(input [15:0] m);
        reg [16:0] t;
        reg [16:0] ds;
        begin
            if (fD) begin
                // Decimal: N and Z come from the BCD-corrected result and C
                // from the (shared) borrow, but V is the binary overflow.
                ds = dsub(av, m, fC, m16);
                if (m16) begin
                    t = {1'b0, A} + {1'b0, ~m} + {16'd0, fC};
                    fV <= (A[15] ^ m[15]) & (A[15] ^ t[15]);
                end else begin
                    t = {9'd0, A[7:0]} + {9'd0, ~m[7:0] & 8'hFF} + {16'd0, fC};
                    fV <= (A[7] ^ m[7]) & (A[7] ^ t[7]);
                end
                fC <= ds[16];
                ld_a(ds[15:0]);
            end else if (m16) begin
                t = {1'b0, A} + {1'b0, ~m} + {16'd0, fC};
                fV <= (A[15] ^ m[15]) & (A[15] ^ t[15]);
                fC <= t[16];
                ld_a(t[15:0]);
            end else begin
                t = {9'd0, A[7:0]} + {9'd0, ~m[7:0] & 8'hFF} + {16'd0, fC};
                fV <= (A[7] ^ m[7]) & (A[7] ^ t[7]);
                fC <= t[8];
                ld_a(t[15:0]);
            end
        end
    endtask

    // read-class execute (called with the full operand, width = rd16)
    task exec_rd(input [15:0] m);
        begin
            case (d_op)
            OP_ORA: ld_a(av | m);
            OP_AND: ld_a(av & m);
            OP_EOR: ld_a(av ^ m);
            OP_ADC: do_adc(m);
            OP_SBC: do_sbc(m);
            OP_CMP: cmp_flags(av, m, m16);
            OP_LDA: ld_a(m);
            OP_LDX: ld_x(m);
            OP_LDY: ld_y(m);
            OP_CPX: cmp_flags(xv, m, x16);
            OP_CPY: cmp_flags(yv, m, x16);
            OP_BIT: begin
                fZ <= ((av & m) == 16'h0000);
                if (IR != 8'h89) begin           // BIT # affects Z only
                    fN <= m16 ? m[15] : m[7];
                    fV <= m16 ? m[14] : m[6];
                end
            end
            OP_REP: set_p(pbyte(fX) & ~m[7:0]);
            OP_SEP: set_p(pbyte(fX) |  m[7:0]);
            default:                             // OP_NOP: WDM
                if (m[7:1] == 7'b1011000) xb <= m[0];    // WDM $B0 / $B1
            endcase
        end
    endtask

    // RMW / accumulator shift-and-step core. op given explicitly so the
    // accumulator forms can run during S_FETCH (before IR is loaded).
    // to_a=1: result goes to A; else to tdata for write-back.
    // Everything it reads is an argument: a function called from a
    // continuous assignment is re-evaluated only when its arguments change.
    function [15:0] rmw_val(input [4:0] op, input [15:0] m, input [15:0] a,
                            input c, input w);
        case (op)
        OP_ASL: rmw_val = {m[14:0], 1'b0};
        OP_ROL: rmw_val = {m[14:0], c};
        OP_LSR: rmw_val = w ? {1'b0, m[15:1]} : {8'h00, 1'b0, m[7:1]};
        OP_ROR: rmw_val = w ? {c, m[15:1]} : {8'h00, c, m[7:1]};
        OP_INC: rmw_val = m + 16'd1;
        OP_DEC: rmw_val = m - 16'd1;
        OP_TSB: rmw_val = m | a;
        OP_TRB: rmw_val = m & ~a;
        default: rmw_val = m;
        endcase
    endfunction

    // A memory RMW's result, from its latched operand: written in S_WBL.
    wire [15:0] rmw_r = rmw_val(d_op, xm, av, fC, m16);

    task rmw_core(input [4:0] op, input [15:0] m, input to_a);
        reg [15:0] r;
        reg c, setc;
        begin
            r = rmw_val(op, m, av, fC, m16);
            c = fC; setc = 1'b0;
            case (op)
            OP_ASL, OP_ROL: begin c = m16 ? m[15] : m[7]; setc = 1'b1; end
            OP_LSR, OP_ROR: begin c = m[0];               setc = 1'b1; end
            default: ;
            endcase
            if (setc) fC <= c;
            if (op == OP_TSB || op == OP_TRB) begin
                fZ <= ((av & m) == 16'h0000);
            end else begin
                fN <= m16 ? r[15] : r[7];
                fZ <= m16 ? (r == 16'h0000) : (r[7:0] == 8'h00);
            end
            if (to_a) begin
                if (m16) A <= r; else A[7:0] <= r[7:0];
            end else begin
                tdata <= r;
            end
        end
    endtask

    // An implied opcode, latched in IR at its fetch and executed in the next
    // cycle (lp), overlapped with the following opcode's fetch.
    task exec_imp;
        begin
            case (IR)
            // ---- flag ops (1 cycle) ----
            8'h18: fC <= 1'b0;                       // CLC
            8'h38: fC <= 1'b1;                       // SEC
            8'h58: fI <= 1'b0;                       // CLI
            8'h78: fI <= 1'b1;                       // SEI
            8'hB8: fV <= 1'b0;                       // CLV
            8'hD8: fD <= 1'b0;                       // CLD
            8'hF8: fD <= 1'b1;                       // SED
            8'hEA: ;                                 // NOP
            // ---- accumulator shifts / inc / dec (1 cycle) ----
            8'h0A: rmw_core(OP_ASL, av, 1'b1);
            8'h2A: rmw_core(OP_ROL, av, 1'b1);
            8'h4A: rmw_core(OP_LSR, av, 1'b1);
            8'h6A: rmw_core(OP_ROR, av, 1'b1);
            8'h1A: rmw_core(OP_INC, av, 1'b1);
            8'h3A: rmw_core(OP_DEC, av, 1'b1);
            // ---- transfers (1 cycle) ----
            8'hAA: ld_x(A);                          // TAX
            8'hA8: ld_y(A);                          // TAY
            8'h8A: ld_a(X);                          // TXA
            8'h98: ld_a(Y);                          // TYA
            8'hBA: ld_x(S);                          // TSX
            8'h9A: S <= fE ? {8'h01, X[7:0]} : X;    // TXS
            8'h9B: ld_y(X);                          // TXY
            8'hBB: ld_x(Y);                          // TYX
            8'h1B: S <= fE ? {8'h01, A[7:0]} : A;    // TCS
            8'h3B: begin                             // TSC
                A <= S; fN <= S[15]; fZ <= (S == 16'h0000);
            end
            8'h5B: begin                             // TCD
                D <= A; fN <= A[15]; fZ <= (A == 16'h0000);
            end
            8'h7B: begin                             // TDC
                A <= D; fN <= D[15]; fZ <= (D == 16'h0000);
            end
            // ---- index inc/dec (1 cycle) ----
            8'hE8: ld_x(X + 16'd1);                  // INX
            8'hCA: ld_x(X - 16'd1);                  // DEX
            8'hC8: ld_y(Y + 16'd1);                  // INY
            8'h88: ld_y(Y - 16'd1);                  // DEY
            // ---- XBA / XCE (1 cycle) ----
            8'hEB: begin                             // XBA
                A <= {A[7:0], A[15:8]};
                fN <= A[15]; fZ <= (A[15:8] == 8'h00);
            end
            8'hFB: begin                             // XCE
                fC <= fE; fE <= fC;
                if (fC) begin                        // entering emulation
                    fM <= 1'b1; fX <= 1'b1;
                    X[15:8] <= 8'h00; Y[15:8] <= 8'h00;
                    S[15:8] <= 8'h01;
                end
            end
            default: ;
            endcase
        end
    endtask

    // PC out of sequence: the queue empties (see the queue logic)
    task jump(input [15:0] v);
        begin
            PC <= v; jmp = 1'b1; jpc = v; jbank = PBR;
        end
    endtask

    // ... and PBR with it (JML, JSL)
    task jumpl(input [7:0] b, input [15:0] v);
        begin
            PBR <= b; PC <= v; jmp = 1'b1; jpc = v; jbank = b;
        end
    endtask

    // queue a push, shortest path to S_PUSH
    task push8(input [7:0] v);
        begin
            push_q <= {v, 24'h0}; push_n <= 3'd1; stk16 <= 1'b0;
            post_push <= PP_FETCH; state <= S_PUSH;
        end
    endtask

    // 16-bit push. The only push16 callers reachable in emulation mode are
    // the new stack ops (PEA/PEI/PER/PHD) -- PHA/PHX/PHY use push8 when 8-bit
    // -- so the 16-bit-stack quirk applies whenever this runs in emulation.
    task push16(input [15:0] v);
        begin
            push_q <= {v, 16'h0}; push_n <= 3'd2; stk16 <= 1'b1;
            post_push <= PP_FETCH; state <= S_PUSH;
        end
    endtask

    // stack pointer step (keeps page 1 in emulation mode, except for the
    // new 16-bit stack ops which step the full 16-bit S)
    task s_dec; S <= (fE & ~stk16) ? {8'h01, S[7:0] - 8'd1} : S - 16'd1; endtask
    task s_inc; S <= (fE & ~stk16) ? {8'h01, S[7:0] + 8'd1} : S + 16'd1; endtask

    // interrupt entry (hardware IRQ/NMI and BRK/COP).
    // pushed_pc: the PC value to push; brkbit: B for the pushed P byte.
    task int_entry(input [15:0] pushed_pc, input brkbit, input [15:0] v);
        begin
            if (fE) begin
                push_q <= {pushed_pc, pbyte(brkbit), 8'h00};
                push_n <= 3'd3;
            end else begin
                push_q <= {PBR, pushed_pc, pbyte(brkbit)};
                push_n <= 3'd4;
            end
            fI <= 1'b1; fD <= 1'b0; PBR <= 8'h00;
            vec <= v;
            post_push <= PP_VEC; stk16 <= 1'b0;
            state <= S_PUSH;
        end
    endtask

    // abort entry: restore the pre-instruction snapshot, then push the
    // snapshotted PBR/PC/P (opcode address, B=0) and vector through the ABORT
    // vector (native $FFE8 / emulation $FFF8).
    task abort_entry;
        reg [7:0] pb;
        reg       e;
        begin
            // With snap_late set the snapshot of what an execute changes is
            // still being taken: those registers are right as they are.
            if (snap_late) begin
                e  = fE;
                pb = {fN, fV, e ? 1'b1 : fM, e ? 1'b0 : fX, fD, fI, fZ, fC};
            end else begin
                e  = sfE;
                pb = {sfN, sfV, e ? 1'b1 : sfM, e ? 1'b0 : sfX,
                      sfD, sfI, sfZ, sfC};
                A <= sA; X <= sX; Y <= sY; xb <= sxb; S <= sS; D <= sD;
                fN <= sfN; fV <= sfV; fM <= sfM; fX <= sfX;
                fZ <= sfZ; fC <= sfC; fE <= sfE;
            end
            DBR <= sDBR;
            if (e) begin push_q <= {sPC, pb, 8'h00}; push_n <= 3'd3; end
            else   begin push_q <= {sPBR, sPC, pb};  push_n <= 3'd4; end
            fI <= 1'b1; fD <= 1'b0; PBR <= 8'h00;
            vec <= e ? 16'hFFF8 : 16'hFFE8;
            post_push <= PP_VEC; stk16 <= 1'b0;
            abort_pend <= 1'b0;
            state <= S_PUSH;
        end
    endtask

    //------------------------------------------------------------------
    // Bus outputs (combinational)
    //------------------------------------------------------------------
    always @* begin
        vld = 1'b0; we = 1'b0; addr = faddr; wdata = 8'h00;
        // status pins: VPA/VDA classify the cycle (00=internal, 10=program,
        // 01=data, 11=opcode fetch); VPB low on vector pulls; MLB low on the
        // read+write of a read-modify-write.
        vpa = 1'b0; vda = 1'b0; vpb_n = 1'b1; mlb_n = 1'b1;
        if (fbusy) begin
            vld = 1'b1; vpa = 1'b1;           // an instruction-queue fill
        end else case (state)
        S_FETCH, S_OPS: ;                    // from the queue: no bus
        S_PTRL, S_PTRH, S_PTRB:
                 begin vld = 1'b1; addr = {ptr_bank, tptr};  vda = 1'b1; end
        S_RDL, S_RDH:
                 begin vld = 1'b1; addr = taddr;  vda = 1'b1; mlb_n = (d_cls != CL_MW); end
        S_WRL:   begin vld = 1'b1; addr = taddr;  we = 1'b1; wdata = stval[7:0];  vda = 1'b1; end
        S_WRH:   begin vld = 1'b1; addr = taddr;  we = 1'b1; wdata = stval[15:8]; vda = 1'b1; end
        S_WBL:   begin vld = 1'b1; addr = taddr;  we = 1'b1; wdata = rmw_r[7:0];  vda = 1'b1; mlb_n = 1'b0; end
        S_WBH:   begin vld = 1'b1; addr = taddr;  we = 1'b1; wdata = tdata[15:8]; vda = 1'b1; mlb_n = 1'b0; end
        S_PUSH:  begin vld = 1'b1; addr = sp_push; we = 1'b1; wdata = push_q[31:24]; vda = 1'b1; end
        S_PULL:  begin vld = 1'b1; addr = pa; vda = 1'b1; end
        S_VECL, S_VECH:
                 begin vld = 1'b1; addr = {8'h00, vec}; vda = 1'b1; vpb_n = 1'b0; end
        S_MVR:   begin vld = 1'b1; addr = {tmid, X};            vda = 1'b1; end
        S_MVW:   begin vld = 1'b1; addr = {DBR, Y}; we = 1'b1; wdata = tdata[7:0]; vda = 1'b1; end
        default: ;
        endcase
        // suppress every write of an instruction being aborted (the abort
        // sequence itself runs with abort_pend cleared and abrt deasserted).
        // `abrt` is included so the very cycle abort is recognized -- which
        // may coincide with the store cycle -- is also suppressed.
        if (abort_pend | abrt) we = 1'b0;
    end

    wire step = rdy | ~vld;                  // a bus cycle ends (or none)

    // The core's states that use the bus. One waits while a queue fill
    // holds the bus, then for its own rdy; every other state advances each
    // cycle, a fill in flight or not.
    wire needs_bus = (state == S_PTRL) | (state == S_PTRH) | (state == S_PTRB) |
                     (state == S_RDL)  | (state == S_RDH)  | (state == S_WRL)  |
                     (state == S_WRH)  | (state == S_WBL)  | (state == S_WBH)  |
                     (state == S_PUSH) | (state == S_PULL) | (state == S_VECL) |
                     (state == S_VECH) | (state == S_MVR)  | (state == S_MVW);
    wire cstep = ~needs_bus | (~fbusy & rdy);
    wire dstate_wr = (d_cls == CL_WR);
    wire [15:0] int_vec = nmi_pend ? (fE ? 16'hFFFA : 16'hFFEA)
                                   : (fE ? 16'hFFFE : 16'hFFEE);

    // branch condition
    reg btake;
    always @* begin
        case (IR[7:6])
        2'b00: btake = (fN == IR[5]);
        2'b01: btake = (fV == IR[5]);
        2'b10: btake = (fC == IR[5]) | (IR == 8'h80);   // BRA
        2'b11: btake = (fZ == IR[5]);
        endcase
    end

    //------------------------------------------------------------------
    // Main state machine
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_VECL; vec <= 16'hFFFC;
            fE <= 1'b1; fM <= 1'b1; fX <= 1'b1; fI <= 1'b1; fD <= 1'b0;
            fC <= 1'b0; fZ <= 1'b0; fV <= 1'b0; fN <= 1'b0;
            A <= 16'h0000; X <= 16'h0000; Y <= 16'h0000;
            S <= 16'h01FF; D <= 16'h0000; DBR <= 8'h00; PBR <= 8'h00;
            PC <= 16'h0000; IR <= 8'h00; xb <= 1'b0; sxb <= 1'b0;
            {d_mode, d_cls, d_op} <= dec(8'h00); d_len <= 2'd1;
            tlo <= 8'h00; tmid <= 8'h00; tptr <= 16'h0000;
            ptr_bank <= 8'h00; taddr <= 24'h0; wrap16 <= 1'b0;
            tdata <= 16'h0000; push_q <= 32'h0; push_n <= 3'd0; stk16 <= 1'b0;
            post_push <= PP_FETCH; pull_idx <= 2'd0;
            taddr_alt <= 24'h0; pa <= 24'h0;
            q <= 64'h0; qn <= 4'd0; fa <= 16'h0000; faddr <= 24'h0;
            fbusy <= 1'b0; fdrop <= 1'b0;
            xp <= 1'b0; xm <= 16'h0000; snap_late <= 1'b0; lp <= 1'b0;
            irq1 <= 1'b1; irq2 <= 1'b1; nmi1 <= 1'b1; nmi2 <= 1'b1;
            nmi_pend <= 1'b0;
            ab <= 1'b1; abort_pend <= 1'b0;
            sA <= 16'h0; sX <= 16'h0; sY <= 16'h0; sS <= 16'h0;
            sD <= 16'h0; sPC <= 16'h0; sDBR <= 8'h0; sPBR <= 8'h0;
            sfN<=1'b0; sfV<=1'b0; sfM<=1'b1; sfX<=1'b1;
            sfD<=1'b0; sfI<=1'b1; sfZ<=1'b0; sfC<=1'b0; sfE<=1'b1;
        end else begin
            // interrupt input synchronizers / NMI edge detect
            irq1 <= irq_n;
            if (step) irq2 <= irq1;
            nmi1 <= nmi_n; nmi2 <= nmi1;
            if (step & nmi_seen) begin nmi_pend <= 1'b1; nmi_seen <= 1'b0; end
            if (nmi2 & ~nmi1) nmi_seen <= 1'b1;
            // abort synchronizer
            ab <= abort_n;

            take = 2'd0; jmp = 1'b0; jpc = PC; jbank = PBR;

            if (cstep) begin
                // Latch a recognized abort; the abort sequence in S_FETCH
                // clears it (that clear is later in source order, so it wins
                // if both fire on the same cycle).
                if (abrt) abort_pend <= 1'b1;

                // The registers an execute changes, for the ABORT snapshot,
                // after a fetch cycle that ran the previous one's execute.
                if (snap_late) begin
                    sA <= A; sX <= X; sY <= Y; sxb <= xb; sS <= S; sD <= D; sfE <= fE;
                    sfN<=fN; sfV<=fV; sfM<=fM; sfX<=fX;
                    sfD<=fD; sfI<=fI; sfZ<=fZ; sfC<=fC;
                    snap_late <= 1'b0;
                end

                case (state)

                //----------------------------------------------------------
                S_FETCH: begin
                    if (abort_pend) begin
                        // the previous instruction was aborted: restore its
                        // snapshot and vector through the ABORT handler (its
                        // execute, if one is pending, never happens)
                        xp <= 1'b0;
                        abort_entry;
                    end else if ((xp | lp) & (intr | fetch_pull | (qn == 4'd0))) begin
                        // The pending execute first: an interrupt pushes P,
                        // and a pull's address comes from S, D and E, which
                        // an implied opcode may change. Fetch again.
                        if (xp) exec_rd(xm);
                        if (lp) exec_imp;
                        xp <= 1'b0; lp <= 1'b0;
                    end else if (intr) begin
                        if (nmi_pend) nmi_pend <= 1'b0;
                        int_entry(PC, 1'b0, int_vec);
                    end else if (qn != 4'd0) begin
                        // The pending execute runs as this opcode is latched:
                        // nothing here reads what it changes.
                        if (xp) exec_rd(xm);
                        if (lp) exec_imp;
                        xp <= 1'b0; lp <= 1'b0;
                        if (xp | lp) snap_late <= 1'b1;
                        // snapshot the pre-instruction state for ABORT
                        sPC <= PC; sPBR <= PBR;
                        sA <= A; sX <= X; sY <= Y; sS <= S; sD <= D; sDBR <= DBR; sxb <= xb;
                        sfN<=fN; sfV<=fV; sfM<=fM; sfX<=fX;
                        sfD<=fD; sfI<=fI; sfZ<=fZ; sfC<=fC; sfE<=fE;
                        PC <= PC + 16'd1; take = 2'd1;
                        case (qb)
                        // ---- pulls / returns ----
                        8'h28, 8'h2B, 8'h68, 8'h7A, 8'hAB, 8'hFA,
                        8'h40, 8'h60, 8'h6B: begin
                            IR <= qb; {d_mode, d_cls, d_op} <= dec_in;
                            pull_idx <= 2'd0; state <= S_PULL;
                            // The "new" pull instructions PLB/PLD/RTL use the
                            // 16-bit stack in emulation mode
                            stk16 <= pull16;
                            pa <= (fE & ~pull16) ? {16'h0001, S[7:0] + 8'd1}
                                                 : {dbank, S + 16'd1};
                        end
                        default: begin
                            IR <= qb; {d_mode, d_cls, d_op} <= dec_in;
                            d_len <= len_in;
                            if (fetch_local) lp <= 1'b1;         // implied
                            else if (fetch_setup) state <= S_IMP; // push, WAI, STP
                            else state <= S_OPS;                  // operands
                        end
                        endcase
                    end
                end

                //----------------------------------------------------------
                // A push, WAI or STP, a cycle after its fetch: what it pushes
                // is then up to date.
                S_IMP: begin
                    case (IR)
                    // ---- pushes ----
                    8'h08: push8(pbyte(1'b1));               // PHP
                    8'h0B: push16(D);                        // PHD
                    8'h48: if (m16) push16(A); else push8(A[7:0]);  // PHA
                    8'h4B: push8(PBR);                       // PHK
                    8'h5A: if (x16) push16(Y); else push8(Y[7:0]);  // PHY
                    8'h8B: push8(DBR);                       // PHB
                    8'hDA: if (x16) push16(X); else push8(X[7:0]);  // PHX
                    8'hCB: state <= S_WAI;
                    8'hDB: state <= S_STP;
                    default: state <= S_FETCH;
                    endcase
                end

                //----------------------------------------------------------
                // The operand bytes, taken together once all are queued: b1-b3
                // from the head, PC at b1, pce past the instruction.
                S_OPS: if (qn >= {2'd0, olen}) begin
                    PC <= pce; take = olen;
                    case (IR)
                    8'h00: int_entry(pce, 1'b1, fE ? 16'hFFFE : 16'hFFE6); // BRK
                    8'h02: int_entry(pce, 1'b1, fE ? 16'hFFF4 : 16'hFFE4); // COP
                    8'h44, 8'h54: begin                                    // MVP/MVN
                        DBR <= b1; tmid <= b2; state <= S_MVR;             // dest, src bank
                    end
                    8'h62: push16(pce + {b2, b1});                         // PER
                    8'hF4: push16({b2, b1});                               // PEA
                    8'h82: begin jump(pce + {b2, b1}); state <= S_FETCH; end // BRL
                    8'hD4: begin                                           // PEI
                        tptr <= dpw ? {D[15:8], b1} : dbase + {8'h00, b1};
                        ptr_bank <= dbank;
                        state <= S_PTRL;
                    end
                    8'h20: begin                                           // JSR abs
                        push_q <= {pcn, 16'h0}; push_n <= 3'd2; stk16 <= 1'b0;
                        post_push <= PP_FETCH;
                        jump({b2, b1});
                        state <= S_PUSH;
                    end
                    8'hFC: begin                                           // JSR (abs,X)
                        push_q <= {pcn, 16'h0}; push_n <= 3'd2; stk16 <= 1'b0;
                        post_push <= PP_PTR;
                        tptr <= {b2, b1} + X; ptr_bank <= PBR;
                        state <= S_PUSH;
                    end
                    8'h4C: begin jump({b2, b1}); state <= S_FETCH; end     // JMP abs
                    8'h6C, 8'hDC: begin                                    // JMP (abs) / JML [abs]
                        tptr <= {b2, b1}; ptr_bank <= 8'h00;
                        state <= S_PTRL;
                    end
                    8'h7C: begin                                           // JMP (abs,X)
                        tptr <= {b2, b1} + X; ptr_bank <= PBR;
                        state <= S_PTRL;
                    end
                    8'h5C: begin jumpl(b3, {b2, b1}); state <= S_FETCH; end // JML long
                    8'h22: begin                                           // JSL long
                        push_q <= {PBR, pce - 16'd1, 8'h00}; push_n <= 3'd3; stk16 <= 1'b1;
                        post_push <= PP_FETCH;
                        jumpl(b3, {b2, b1});
                        state <= S_PUSH;
                    end
                    default: case (d_mode)
                    MD_REL: begin
                        if (btake) jump(pce + {{8{b1[7]}}, b1});
                        state <= S_FETCH;
                    end
                    MD_IMM: begin
                        xm <= rd16 ? {b2, b1} : {8'h00, b1}; xp <= 1'b1;
                        state <= S_FETCH;
                    end
                    // Direct-page modes: when E=1 and DL=0 the base offset
                    // (dp + index) wraps within page 0 with high byte = DH;
                    // otherwise it is a 16-bit add in bank 0 (from dbase in
                    // dbank, in banked mode). The word/pointer upper bytes
                    // are always fetched at base+1 (16-bit).
                    MD_DP: begin
                        taddr <= dpw ? {8'h00, D[15:8], b1}
                                     : {dbank, dbase + {8'h00, b1}};
                        wrap16 <= 1'b1;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_DPX: begin
                        taddr <= dpw ? {8'h00, D[15:8], b1 + X[7:0]}
                                     : {dbank, dbase + {8'h00, b1} + X};
                        wrap16 <= 1'b1;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_DPY: begin
                        taddr <= dpw ? {8'h00, D[15:8], b1 + Y[7:0]}
                                     : {dbank, dbase + {8'h00, b1} + Y};
                        wrap16 <= 1'b1;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_SR: begin
                        taddr <= {dbank, S + {8'h00, b1}};
                        wrap16 <= 1'b1;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_IDX: begin
                        tptr <= dpw ? {D[15:8], b1 + X[7:0]}
                                    : dbase + {8'h00, b1} + X;
                        ptr_bank <= dbank;
                        state <= S_PTRL;
                    end
                    MD_IDP, MD_IDY, MD_IDL, MD_ILY: begin
                        tptr <= dpw ? {D[15:8], b1}
                                    : dbase + {8'h00, b1};
                        ptr_bank <= dbank;
                        state <= S_PTRL;
                    end
                    MD_SRY: begin
                        tptr <= S + {8'h00, b1}; ptr_bank <= dbank;
                        state <= S_PTRL;
                    end
                    MD_ABS: begin
                        taddr <= {DBR, b2, b1}; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_ABX: begin
                        taddr <= {DBR, b2, b1} + {8'h00, X}; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_ABY: begin
                        taddr <= {DBR, b2, b1} + {8'h00, Y}; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    default: begin                                         // ABL / ALX
                        taddr <= (d_mode == MD_ALX)
                                 ? {b3, b2, b1} + {8'h00, X}
                                 : {b3, b2, b1};
                        wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    endcase
                    endcase
                end

                //----------------------------------------------------------
                S_PTRL: begin
                    tlo <= rdata; tptr <= tptr + 16'd1;
                    state <= S_PTRH;
                end

                S_PTRH: begin
                    tptr <= tptr + 16'd1;
                    case (IR)
                    8'h6C, 8'h7C, 8'hFC:                                   // jumps via pointer
                        begin jump({rdata, tlo}); state <= S_FETCH; end
                    8'hD4: push16({rdata, tlo});                           // PEI
                    8'hDC: begin tmid <= rdata; state <= S_PTRB; end       // JML [abs]
                    default: case (d_mode)
                    MD_IDL, MD_ILY: begin tmid <= rdata; state <= S_PTRB; end
                    MD_IDY, MD_SRY: begin
                        taddr <= {DBR, rdata, tlo} + {8'h00, Y}; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    default: begin                                         // IDX / IDP
                        taddr <= {DBR, rdata, tlo}; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    endcase
                    endcase
                end

                S_PTRB: begin
                    case (IR)
                    8'hDC: begin                                           // JML [abs]
                        jump({tmid, tlo}); PBR <= rdata; state <= S_FETCH;
                    end
                    default: begin                                         // IDL / ILY
                        taddr <= (d_mode == MD_ILY)
                                 ? {rdata, tmid, tlo} + {8'h00, Y}
                                 : {rdata, tmid, tlo};
                        wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    endcase
                end

                //----------------------------------------------------------
                // The data is latched (xm), not used: a read's execute runs
                // in the next fetch cycle, an RMW's in S_WBL.
                S_RDL: begin
                    if (rd16) begin
                        tlo <= rdata;
                        taddr <= taddr1; taddr_alt <= taddr;
                        state <= S_RDH;
                    end else if (d_cls == CL_MW) begin
                        xm <= {8'h00, rdata};
                        state <= S_WBL;
                    end else begin
                        xm <= {8'h00, rdata}; xp <= 1'b1;
                        state <= S_FETCH;
                    end
                end

                S_RDH: begin
                    xm <= {rdata, tlo};
                    if (d_cls == CL_MW) begin
                        taddr <= taddr_alt; taddr_alt <= taddr;
                        state <= S_WBL;
                    end else begin
                        xp <= 1'b1;
                        state <= S_FETCH;
                    end
                end

                S_WBL: begin
                    rmw_core(d_op, xm, 1'b0);
                    if (rd16) begin taddr <= taddr_alt; state <= S_WBH; end
                    else state <= S_FETCH;
                end
                S_WBH: state <= S_FETCH;
                S_WRL: begin
                    if (st16) begin taddr <= taddr1; state <= S_WRH; end
                    else state <= S_FETCH;
                end
                S_WRH: state <= S_FETCH;

                //----------------------------------------------------------
                S_PUSH: begin
                    s_dec;
                    push_q <= push_q << 8;
                    push_n <= push_n - 3'd1;
                    if (push_n == 3'd1) begin
                        if (fE & stk16) S[15:8] <= 8'h01;   // restore page 1
                        case (post_push)
                        PP_VEC:  state <= S_VECL;
                        PP_PTR:  state <= S_PTRL;
                        default: state <= S_FETCH;
                        endcase
                    end
                end

                S_PULL: begin
                    s_inc;
                    pa <= (fE & ~stk16) ? {16'h0001, pa[7:0] + 8'd1}
                                        : {pa[23:16], pa[15:0] + 16'd1};
                    pull_idx <= pull_idx + 2'd1;
                    case (IR)
                    8'h28: begin set_p(rdata); state <= S_FETCH; end       // PLP
                    8'hAB: begin                                           // PLB
                        DBR <= rdata;
                        fN <= rdata[7]; fZ <= (rdata == 8'h00);
                        if (fE) S[15:8] <= 8'h01;           // restore page 1
                        state <= S_FETCH;
                    end
                    8'h2B:                                                 // PLD
                        if (pull_idx == 2'd0) tlo <= rdata;
                        else begin
                            D <= {rdata, tlo};
                            fN <= rdata[7]; fZ <= ({rdata, tlo} == 16'h0000);
                            if (fE) S[15:8] <= 8'h01;       // restore page 1
                            state <= S_FETCH;
                        end
                    8'h68:                                                 // PLA
                        if (!m16) begin
                            ld_a({8'h00, rdata}); state <= S_FETCH;
                        end else if (pull_idx == 2'd0) tlo <= rdata;
                        else begin ld_a({rdata, tlo}); state <= S_FETCH; end
                    8'h7A:                                                 // PLY
                        if (!x16) begin
                            ld_y({8'h00, rdata}); state <= S_FETCH;
                        end else if (pull_idx == 2'd0) tlo <= rdata;
                        else begin ld_y({rdata, tlo}); state <= S_FETCH; end
                    8'hFA:                                                 // PLX
                        if (!x16) begin
                            ld_x({8'h00, rdata}); state <= S_FETCH;
                        end else if (pull_idx == 2'd0) tlo <= rdata;
                        else begin ld_x({rdata, tlo}); state <= S_FETCH; end
                    8'h60:                                                 // RTS
                        if (pull_idx == 2'd0) tlo <= rdata;
                        else begin
                            jump({rdata, tlo} + 16'd1); state <= S_FETCH;
                        end
                    8'h6B:                                                 // RTL
                        case (pull_idx)
                        2'd0: tlo <= rdata;
                        2'd1: jump({rdata, tlo} + 16'd1);
                        default: begin
                            PBR <= rdata;
                            if (fE) S[15:8] <= 8'h01;       // restore page 1
                            state <= S_FETCH;
                        end
                        endcase
                    default:                                               // RTI (0x40)
                        case (pull_idx)
                        2'd0: set_p(rdata);
                        2'd1: tlo <= rdata;
                        2'd2: begin
                            jump({rdata, tlo});
                            if (fE) state <= S_FETCH;
                        end
                        default: begin PBR <= rdata; state <= S_FETCH; end
                        endcase
                    endcase
                end

                //----------------------------------------------------------
                S_VECL: begin tlo <= rdata; vec <= vec + 16'd1; state <= S_VECH; end
                S_VECH: begin jump({rdata, tlo}); state <= S_FETCH; end

                //----------------------------------------------------------
                S_MVR: begin
                    tdata[7:0] <= rdata;
                    state <= S_MVW;
                end

                // Internal block-move loop: after FETCH/OPS set up the
                // banks, spin MVR/MVW at 2 cycles/byte without re-fetching the
                // instruction. PC already points past the MVN/MVP.
                //   - count exhausted (C wrapped to $FFFF): fall through to the
                //     next instruction.
                //   - interrupt pending: rewind PC by 3 onto the opcode so the
                //     pushed PC re-enters the move, then let S_FETCH take it.
                //   - otherwise: loop back to MVR for the next byte.
                S_MVW: begin
                    if (x16) begin
                        X <= (IR == 8'h54) ? X + 16'd1 : X - 16'd1;
                        Y <= (IR == 8'h54) ? Y + 16'd1 : Y - 16'd1;
                    end else begin
                        X <= {8'h00, (IR == 8'h54) ? X[7:0] + 8'd1 : X[7:0] - 8'd1};
                        Y <= {8'h00, (IR == 8'h54) ? Y[7:0] + 8'd1 : Y[7:0] - 8'd1};
                    end
                    A <= A - 16'd1;
                    if (A == 16'h0000)
                        state <= S_FETCH;
                    else if (intr) begin
                        jump(PC - 16'd3);
                        state <= S_FETCH;
                    end else
                        state <= S_MVR;
                end

                //----------------------------------------------------------
                S_WAI: begin
                    if (nmi_pend | ~irq2) begin
                        if (nmi_pend | ~fI) begin
                            if (nmi_pend) nmi_pend <= 1'b0;
                            int_entry(PC, 1'b0, int_vec);
                        end else
                            state <= S_FETCH;
                    end
                end

                S_STP: ;                       // only reset leaves this state

                default: state <= S_FETCH;
                endcase
            end

            //--------------------------------------------------------------
            // The instruction queue: the byte taken this cycle, the fill
            // landing this cycle, a jump, and the next fill. A fill starts
            // only in a cycle the core is off the bus, when a whole word
            // will fit, and its address is latched: the bus holds it to rdy.
            begin : queue_logic
                // Both outcomes are worked out without rdy -- the fill
                // landing this cycle or not -- and rdy, which arrives late
                // (through the cache's compare), only picks one.
                reg [63:0] qq, qf;
                reg [3:0]  qc, qcf;
                reg [2:0]  nf;
                reg [31:0] fw;
                reg        land, st_n, st_f;
                qq = q >> {take, 3'b000};
                qc = qn - {2'd0, take};
                if (r32) begin
                    fw = rdata32 >> {faddr[1:0], 3'b000};
                    nf = 3'd4 - {1'b0, faddr[1:0]};
                end else begin
                    fw = {24'h0, rdata};
                    nf = 3'd1;
                end
                qf  = qq | ({32'h0, fw} << {qc, 3'b000});
                qcf = qc + {1'b0, nf};
                land = fbusy & rdy & ~fdrop & ~jmp;  // a fill lands now
                if (jmp) begin
                    q <= 64'h0; qn <= 4'd0; fa <= jpc;
                end else if (land) begin
                    q <= qf; qn <= qcf; fa <= fa + {13'd0, nf};
                end else begin
                    q <= qq; qn <= qc;
                end
                if (fbusy & rdy) begin
                    fbusy <= 1'b0; fdrop <= 1'b0;
                end else if (fbusy & jmp)
                    fdrop <= 1'b1;
                // The next fill: once the bus is free (no fill, or this one
                // ending), in a cycle the core is off it, when a word will
                // fit. (A jump out of a bus state -- a return, a vector, a
                // pointer -- may change PBR a cycle later, but the next state
                // then starts no fill until it is off the bus.)
                st_n = ~needs_bus & ~((state == S_FETCH) & (intr | abort_pend));
                st_f = st_n & (jmp | (qcf <= 4'd4));   // after a fill lands
                st_n = st_n & (jmp | (qc  <= 4'd4));   // with none landing
                if (fbusy ? (rdy & (fdrop | jmp ? st_n : st_f)) : st_n) begin
                    fbusy <= 1'b1; fdrop <= 1'b0;
                    if (jmp) begin
                        faddr <= {jbank, jpc}; fa <= jpc;
                    end else if (fbusy & ~fdrop)
                        faddr <= {PBR, fa + {13'd0, nf}};
                    else
                        faddr <= {PBR, fa};
                end
            end
        end
    end

endmodule

`default_nettype wire
