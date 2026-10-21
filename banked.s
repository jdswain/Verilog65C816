; banked.s - the core's banked direct page and stack (docs/BankedDP.md),
; checked on the core (make banked: tb_cpu, assembled with -D BENCH=1) and
; on em16 -fpga (65Tools/em16/test/banked.sh, -D BENCH=0), which must agree.
;
; Each check has a number; the first that fails is reported: on the test
; bench by a write of the number to $F000 (0 is a allok), under em16 on
; the serial port. Bank 1 holds the banked direct page and stack, as the
; test bench has RAM in banks 0 and 1 only.

                cpu = "65C816"

scc_ctl         = $0822
scc_data        = $0823
brk_pc          = $1F00         ; the PC the BRK handler found stacked

if BENCH {
                org = 0
                data.b 0        ; the test bench's memory image starts at 0
}
                org = $E000

; cmp with an immediate, and fail with number n if it differs
chk             macro val, n {
                cmp #val
                beq .ok
                lda #n
                jmp failed
.ok:
}

reset:          clc
                xce
                rep #$30
                longa = on
                longi = on
                ldx #$01FF
                txs
if BENCH == 0 {
                sep #$20
                longa = off
                lda scc_ctl
                lda #5
                sta scc_ctl
                lda #$68                ; WR5: transmit on
                sta scc_ctl
                rep #$20
                longa = on
}

; the mode is off out of reset: D = $0130 is the bank 0 address $000130
                lda #$0130
                tcd
                lda #$1111
                sta $10
                lda.l $000140
                chk $1111, 1

; on: D = $0130 is bank 1, page $30
                wdm #$B1
                lda #$2222
                sta $10
                lda.l $013010
                chk $2222, 2
                lda.l $000140
                chk $1111, 3
                lda $10
                chk $2222, 4
                inc $10                 ; read-modify-write
                lda.l $013010
                chk $2223, 5

; dp,X wraps within the bank: $FF00 + $20 + $0100 is $01_0020
                lda #$01FF
                tcd
                ldx #$0100
                lda #$3333
                sta $20,x
                lda.l $010020
                chk $3333, 6
; and so does the second byte of a word: $01_FFFF, then $01_0000
                lda #$4455
                sta $FF
                sep #$20
                longa = off
                lda.l $01FFFF
                chk $55, 7
                lda.l $010000
                chk $44, 8
                rep #$20
                longa = on

; pointers come from the direct page's bank, the data from DBR
                lda #$0130
                tcd
                lda #$2000
                sta $30                 ; $01_3030: -> $00_2000
                lda #$6666
                sta.l $002000
                ldy #0
                lda ($30),y
                chk $6666, 9
                lda #$6677
                sta ($30)
                lda.l $002000
                chk $6677, 10
                ldx #2
                lda ($2E,x)
                chk $6677, 11
                lda #$5000              ; $01_3040: -> $01_5000
                sta $40
                lda #$0001
                sta $42
                lda #$7777
                sta.l $015000
                lda [$40]
                chk $7777, 12

; the stack is in the direct page's bank
                ldx #$40FF
                txs
                lda #$8899
                pha
                lda.l $0140FE
                chk $8899, 13
                pla
                chk $8899, 14
                pea $ABCD
                lda 1,s
                chk $ABCD, 15
                lda.l $0140FE
                chk $ABCD, 16
                pla
                pea $2000
                ldy #0
                lda (1,s),y
                chk $6677, 17
                pla
                pei ($30)
                lda.l $0140FE
                chk $2000, 18
                pla
                jsr sub
ret:            lda brk_pc
                chk ret-1, 19

; BRK pushes PBR, PC and P there too
                brk
                data.b 0
brk_ret:        lda brk_pc
                chk brk_ret, 20
                tsc
                chk $40FF, 21

; PLD moves the stack: pulled from bank 1, the next push goes to bank 0
                pea $0000
                pld
                lda #$1234
                pha
                lda.l $0040FE
                chk $1234, 22
                lda.l $0140FE
                chk $0000, 23
                pla
                pea $0130               ; and back
                pld
                lda #$5678
                pha
                lda.l $0140FE
                chk $5678, 24
                pla

; WDMs other than $B0 and $B1 leave the mode alone
                wdm #$42
                lda #$9ABC
                sta $50
                lda.l $013050
                chk $9ABC, 25

; emulation mode does not bank: page 1 of bank 0, D a bank 0 address
                sec
                xce
                sep #$30
                longa = off
                longi = off
                lda #$99
                pha
                lda.l $0001FF
                chk $99, 26
                pla
                lda #$AA
                sta $10
                lda.l $000140
                chk $AA, 27
                clc
                xce
                rep #$30
                longa = on
                longi = on
                ldx #$40FF
                txs
                lda #$BBCC              ; native again: banked again
                sta $10
                lda.l $013010
                chk $BBCC, 28

; off again
                wdm #$B0
                lda #$DDEE
                sta $10
                lda.l $000140
                chk $DDEE, 29
                lda #$0000
                tcd
                ldx #$01FF
                txs
                jmp allok

; the return address JSR stacked, as the stack holds it in bank 1
sub:            lda.l $0140FE
                sta brk_pc
                lda 1,s
                cmp brk_pc
                beq .same
                lda #0                  ; differs: check 19 fails
                sta brk_pc
.same:          rts

; the PC BRK stacked (PBR at $40FF, PC at $40FD, P at $40FC)
brk_h:          lda.l $0140FD
                sta brk_pc
                rti

; the number in A (0: all passed), in whatever mode the check left
allok:           lda #0
failed:           sep #$20
                longa = off
                sta.l brk_pc
                clc
                xce
                rep #$10
                longi = on
                wdm #$B0
                pea $0000
                pld
                ldx #$01FF
                txs
                lda brk_pc
if BENCH {
                sta $F000
                stp
} else {
                bne .bad
                ldx #s_ok
                jsr puts
                bra done
.bad:           ldx #s_fail
                jsr puts
                lda brk_pc
                jsr hex
done:           lda #13
                jsr putc
                lda #10
                jsr putc
                stp

putc:           pha
.wt:            lda scc_ctl
                and #$04
                beq .wt
                pla
                sta scc_data
                rts

puts:           lda.w 0,x
                beq .done
                jsr putc
                inx
                bra puts
.done:          rts

hex:            pha
                lsr a
                lsr a
                lsr a
                lsr a
                jsr .nib
                pla
.nib:           and #$0F
                ora #$30
                cmp #$3A
                bcc .dig
                adc #6
.dig:           jmp putc

s_ok:           text.0 "banked: ok"
s_fail:         text.0 "banked: fail "
}

                fill $FFE6-pc, $FF
                data.w brk_h            ; native BRK
                fill $FFFC-pc, $FF
                data.w reset, reset
