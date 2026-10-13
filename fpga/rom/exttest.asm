********************************************************************************
* exttest - exercise the external peripheral bus bridge                        *
*                                                                              *
* With nothing plugged into the connector every read should return $FF (the    *
* data pins are pulled up internally) and no access should hang: that alone    *
* proves the window decodes, the bus FSM runs a full cycle and acks, and the   *
* CPU is released again. On a scope you should also see PHI0 free-running at   *
* ~1 MHz and IO0# pulsing low once per read.                                   *
*                                                                              *
* With a card attached the register dump becomes the card's own registers.     *
********************************************************************************

	include "mon-fixes/65816.asm"

	section "text"
	org=$e000

	ser_base   = $0200
	ser_data   = ser_base + 0
	ser_status = ser_base + 1

	ext_ctrl   = $0340	;w: bit0 = hold RES.  r: bit0 = card IRQ
	ext_win    = $0800	;+$00 card0, +$10 card1, +$20 card2, +$30 card3

start	native
	short_a
	long_i
	ldx #str_hello
	jsr puts

	;; ---- pulse RES to the cards, then release ----
	lda #$01
	sta ext_ctrl
	ldx #2000		;~ms at 25 MHz, far longer than any card needs
resdly	dex
	bne resdly
	stz ext_ctrl

	ldx #str_ctrl
	jsr puts
	lda ext_ctrl
	jsr puthex8
	ldx #str_crlf
	jsr puts

	;; ---- dump 16 registers from each of the four cards ----
	ldy #0			;card number
cardloop ldx #str_card
	jsr puts
	tya
	jsr puthex8
	lda #$3a		;':'
	jsr putc
	lda #$20
	jsr putc

	phy
	tya
	asl a
	asl a
	asl a
	asl a			;card * 16
	tax
regloop	lda.w ext_win,x
	jsr puthex8
	lda #$20
	jsr putc
	inx
	txa
	and #$0f
	bne regloop
	ply

	ldx #str_crlf
	jsr puts
	iny
	cpy #4
	bne cardloop

	;; ---- a write, to prove the write path completes too ----
	ldx #str_wr
	jsr puts
	lda #$5a
	sta.w ext_win+3
	lda.w ext_win+3
	jsr puthex8
	ldx #str_crlf
	jsr puts

	ldx #str_done
	jsr puts
halt	bra halt

puts	lda $0000,x
	beq puts_end
	jsr putc
	inx
	bra puts
puts_end rts

putc	pha
putc0	lda ser_status
	and #$10
	beq putc0
	pla
	sta ser_data
	rts

puthex8	pha
	lsr a
	lsr a
	lsr a
	lsr a
	jsr puthexnib
	pla
	and #$0f
puthexnib cmp #$0a
	bcc phn_dig
	adc #$36
	bra phn_out
phn_dig	adc #$30
phn_out	jmp putc

str_hello text.0 "external bus test",$0d,$0a
str_ctrl  text.0 "ctrl="
str_card  text.0 "card "
str_wr    text.0 "write $5A to card0 reg3, reads back "
str_done  text.0 "done",$0d,$0a
str_crlf  text.0 $0d,$0a

	;; Reset vector, and IRQ/BRK in emulation mode
	org=$fffc
	data.w start
	data.w start
