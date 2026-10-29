; irqwait.s - interrupts taken while the bus waits (make irqwait: tb_irqwait).
;
; A loop in banked mode, its direct page and stack in bank 3, with pushes
; and pulls, PHD/PLD, PHB/PLB, MVN, JSR/RTS and JSL/RTL, under an IRQ the
; test bench raises every so many cycles. The handler is OS16's
; (Kernel/Switch.s): the registers onto the process's stack, D and S
; saved, the stack moved to bank 0, the tick counted and acknowledged, D
; then S restored, RTI. The loop checks what it pulls; at the end it
; reports a checksum of its work, which must be the same with and without
; the IRQ and the wait states.
;
; Ports (the test bench): $F000 done (the byte is an error number, 0 ok),
; $F002 the IRQ acknowledged, $F010-$F013 the checksum and the ticks.

                cpu = "65C816"

                org = 0
                data.b 0
                org = $8000

dp_d            = $034D         ; the process: direct page $03:4D00
proc_s          = $6DDC         ; and its stack, $03:6DDC down
kpage           = $00FE         ; the kernel's direct page, $00:FE00
irq_top         = $EFFF         ; the interrupt stack
save_d          = $FE00         ; bank 0: the process's D and S
save_s          = $FE02
ticks           = $FE04

sum             = $00           ; direct page (bank 3)
count           = $02
tmp             = $04

src             = $020000       ; MVN's source and destination, bank 2
dst             = $021000

reset:          clc
                xce
                rep #$30
                longa = on
                longi = on
                wdm #$B1                ; banked
                lda #0
                sta.l ticks
                ldx #0                  ; the source block: byte i is i * 7
                txa
.fill:          sep #$20
                longa = off
                sta.l src,x
                clc
                adc #7
                rep #$20
                longa = on
                inx
                cpx #256
                bne .fill
                lda #dp_d
                tcd
                lda #proc_s
                tcs
                stz sum
                lda #500
                sta count
                cli

loop:           lda count               ; pushes and pulls of each width
                pha
                ldx #$1234
                phx
                ldy count
                phy
                sep #$30
                longa = off
                longi = off
                pha
                phb
                pea $0202
                plb
                plb                     ; the data bank 2
                lda #$5A
                pha
                pla
                cmp #$5A
                bne bad
                plb
                pla
                rep #$30
                longa = on
                longi = on
                ply
                cpy count
                bne bad
                plx
                cpx #$1234
                bne bad
                pla
                cmp count
                bne bad
                phd                     ; PHD/PLD, and TCD in the bank
                lda #$0340
                tcd
                lda $D0                 ; a read of $03:40D0
                pld
                tdc
                cmp #dp_d
                bne bad
                jsr sub                 ; JSR/RTS, JSL/RTL
                jsl lsub
                lda count               ; MVN: 64 bytes, from count's low bits
                and #$00BF
                tax
                ldy #dst & $FFFF
                lda #63
                phb
                mvn 2,2
                plb
                lda.l dst+17            ; into the sum
                and #$00FF
                clc
                adc sum
                asl a
                adc #0
                sta sum
                dec count
                bne loop

                sei
                lda sum
                sta.l $00F010
                lda.l ticks
                sta.l $00F012
                sep #$20
                longa = off
                lda #0
                sta.l $00F000
                stp

                longa = on
bad:            sep #$20
                longa = off
                lda #1
                sta.l $00F000
                stp
                longa = on

sub:            lda sum
                eor #$A5A5
                sta tmp
                lda tmp
                eor #$A5A5
                cmp sum
                bne bad
                rts

lsub:           pha
                pla
                rtl

; OS16's handler, Kernel/Switch.s
irq:            rep #$30
                pha
                phx
                phy
                phb
                tsc
                tay
                tdc
                tax
                lda #kpage
                tcd
                txa
                sta.l save_d
                tya
                sta.l save_s
                lda #irq_top
                tcs
                pea $0000
                plb
                plb
                lda.a ticks
                inc a
                sta.a ticks
                sep #$20
                longa = off
                lda #0
                sta.a $F002             ; acknowledged
                rep #$20
                longa = on
                lda.a save_s
                tay
                lda.a save_d
                tcd                     ; D first: S is in D's bank
                tyx
                txs
                plb
                ply
                plx
                pla
                rti

                fill $FFEE-pc, $FF
                data.w irq              ; native IRQ
                fill $FFFC-pc, $FF
                data.w reset, reset
