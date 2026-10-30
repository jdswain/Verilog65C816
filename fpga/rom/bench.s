; bench.s - a CPU benchmark for the SoC simulation (tb_soc): code running
; from cached SDRAM, timed with the tick timer, which counts every clock at
; the simulation's default 25.2 MHz. The kernels are copied to $01:2000 and
; run there, each timed on its own, and each prints a result to check:
;
;   sieve   the primes below 1024 by Eratosthenes: 8-bit flags, abs,X
;   sum     a checksum of 512 bytes through a JSR per byte, DP variables
;   copy    512 bytes copied 16 bits at a time with abs,X and abs,Y
;   walk    a 256-node linked list walked through (dp),Y, 4 times
;
; It prints "name result cycles" a line each, then "bench: done".
; Assemble with 65Tools' as: as -o bench.mem bench.s

                cpu = "65C816"
                org = $E000

tmr_reload      = $0450
tmr_ctrl        = $0452
tmr_ticks       = $0458
tmr_now         = $0454
scc_ctl         = $0822
scc_data        = $0823

run             = $012000       ; where the kernels run (SDRAM)
rk              = run & $FFFF   ; the kernels' offset in their bank, for a JSR
flags           = $014000       ; the sieve's flags
src             = $015000
dst             = $016000
nodes           = $017000       ; 256 nodes of 4 bytes: next (16), value (16)

; direct page (bank 0, D = 0)
t0              = $00           ; start time, 32 bits: ticks * 65536 + count
ptr             = $04
sum             = $06
cnt             = $08
res             = $0A

reset:          clc
                xce
                rep #$30
                longa = on
                longi = on
                ldx #$01FF
                txs
                lda #0
                tcd
                sep #$20
                longa = off
                lda scc_ctl
                lda #5
                sta scc_ctl
                lda #$68
                sta scc_ctl
                stz tmr_reload          ; a full 65536-count period
                stz tmr_reload+1
                lda #1
                sta tmr_ctrl
                rep #$20
                longa = on

                ldx #0                  ; the kernels into SDRAM
.cp:            lda.l kernels,x
                sta.l run,x
                inx
                inx
                cpx #kernels_end-kernels
                bcc .cp

                ldx #0                  ; the copy's source: i * 3
                lda #0
.fs:            sta.l src,x
                clc
                adc #$0303
                inx
                inx
                cpx #2048
                bcc .fs

                ldx #0                  ; the list: node i -> node (i*5+1) & 255
.fl:            txa
                lsr a
                lsr a                   ; i
                sta res
                asl a
                asl a
                adc res                 ; i*5
                inc a
                and #$00FF
                asl a
                asl a
                clc
                adc #nodes & $FFFF
                sta.l nodes,x           ; next
                lda res
                sta.l nodes+2,x         ; value = i
                inx
                inx
                inx
                inx
                cpx #1024
                bcc .fl

                ldx #s_sieve
                ldy #k_sieve-kernels
                jsr bench
                ldx #s_sum
                ldy #k_sum-kernels
                jsr bench
                ldx #s_copy
                ldy #k_copy-kernels
                jsr bench
                ldx #s_walk
                ldy #k_walk-kernels
                jsr bench
                ldx #s_done
                jsr puts
                stp

; Time the kernel at run + Y; print the name at X, its result and cycles.
bench:          jsr puts
                sty ptr
                jsr now
                sta t0
                stx t0+2
                phk                     ; JSL run + Y via RTL
                per .back-1
                sep #$20
                longa = off
                lda #run >> 16
                pha
                rep #$20
                longa = on
                lda ptr
                clc
                adc #(run & $FFFF) - 1
                pha
                rtl
.back:          sta res
                jsr now
                sec
                sbc t0
                sta cnt
                txa
                sbc t0+2
                tax
                lda res
                jsr hex16
                lda #' '
                jsr putc
                txa
                jsr hex16
                lda cnt
                jsr hex16
                jsr crlf
                rts

; The time: A low 16 bits, X high, in clocks.
now:            lda tmr_ticks           ; reading +8 latches TICKS and NOW
                tax
                lda tmr_now
                eor #$FFFF              ; counts gone in this period
                rts

hex16:          pha
                xba
                jsr hex8
                pla
hex8:           pha
                lsr a
                lsr a
                lsr a
                lsr a
                jsr .nib
                pla
.nib:           and #$000F
                cmp #10
                bcc .dig
                adc #6
.dig:           adc #$30
                ; fall through
putc:           php
                sep #$20
                longa = off
                pha
.wt:            lda scc_ctl
                and #$04
                beq .wt
                pla
                sta scc_data
                plp
                rts
                longa = on

puts:           php
                sep #$20
                longa = off
.lp:            lda 0,x
                beq .end
                jsr putc
                inx
                bra .lp
.end:           plp
                rts
                longa = on

crlf:           lda #13
                jsr putc
                lda #10
                jmp putc

s_sieve:        text.0 "sieve "
s_sum:          text.0 "sum   "
s_copy:         text.0 "copy  "
s_walk:         text.0 "walk  "
s_done:         text.0 "bench: done", 13, 10

; ---- the kernels: copied to run, so a JSR names its target's copy, entered by JSL,
; native mode, A and X/Y 16 bits, D = 0; each returns its result in A ----
kernels:
k_sieve:        phb
                pea $0101
                plb
                plb                     ; DBR = 1
                ldx #0
                lda #0
.clr:           sta flags & $FFFF,x
                inx
                inx
                cpx #1024
                bcc .clr
                stz cnt                 ; primes found
                ldx #2
.next:          sep #$20
                longa = off
                lda flags & $FFFF,x
                rep #$20
                longa = on
                bne .skip
                inc cnt
                stx ptr                 ; step
                txa
                asl a
                tay
.mark:          cpy #1024
                bcs .skip
                sep #$20
                longa = off
                lda #1
                sta flags & $FFFF,y
                rep #$20
                longa = on
                tya
                clc
                adc ptr
                tay
                bra .mark
.skip:          inx
                cpx #1024
                bcc .next
                lda cnt
                plb
                rtl

k_sum:          phb
                pea $0101
                plb
                plb
                stz sum
                ldx #0
.sl:            jsr .add-kernels+rk     ; the copy's address, not the ROM's
                inx
                cpx #512
                bcc .sl
                lda sum
                plb
                rtl
.add:           sep #$20
                longa = off
                lda src & $FFFF,x
                rep #$20
                longa = on
                and #$00FF
                clc
                adc sum
                asl a
                adc #0
                sta sum
                rts

k_copy:         phb
                pea $0101
                plb
                plb
                ldx #0
                txy
.cl:            lda src & $FFFF,x
                sta dst & $FFFF,y
                inx
                inx
                iny
                iny
                cpx #512
                bcc .cl
                lda.a dst+510
                plb
                rtl

k_walk:         phb
                pea $0101
                plb
                plb
                lda #4
                sta cnt
                stz sum
.w1:            lda #nodes & $FFFF
                sta ptr
                ldx #256
.w2:            ldy #2
                lda (ptr),y             ; value
                clc
                adc sum
                sta sum
                lda (ptr)               ; next
                sta ptr
                dex
                bne .w2
                dec cnt
                bne .w1
                lda sum
                plb
                rtl
kernels_end:

                fill $FFFC-pc, $FF
                data.w reset, reset
