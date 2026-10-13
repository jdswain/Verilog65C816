********************************************************************************
* memtest - exercise the SDRAM and prove that refresh retains data             *
*                                                                              *
* Fills banks $01..lastbank with an address-derived pattern, waits several      *
* seconds, then verifies. Filling first and verifying last is deliberate: the   *
* earliest bytes written are checked many seconds later, which is what actually  *
* tests refresh. A write-then-immediately-read test never touches the 64ms      *
* retention window and would pass even with refresh broken.                    *
*                                                                              *
* The pattern includes the bank number. With a bank-independent pattern every   *
* bank holds identical data, so a broken bank decode that aliased them all onto *
* one would still compare equal and pass.                                      *
*                                                                              *
* NOTE: bank-crossing accesses must use the .w suffix. Written as              *
* `sta $0000,x` the assembler picks direct-page indexed ($95), which always     *
* addresses bank 0 and ignores DBR -- so the test silently wrote over its own   *
* variables instead of the bank under test. `sta.w` forces abs,X ($9D), which   *
* is DBR-relative. (`!$0000` does not force absolute here either: the `!` is    *
* parsed as an operator, quietly yielding `sta $01,x`.)                        *
********************************************************************************

	include "mon-fixes/65816.asm"

	section text
	org=$e000
	entry start

	ser_base   = $0200
	ser_data   = ser_base + 0
	ser_status = ser_base + 1

	;; Direct page scratch. DP addressing is always bank 0, so these stay
	;; reachable while DBR points at the bank under test.
	tmp        = $0010
	curbank    = $0012
	failbank   = $0013

	testlen    = $2000	;bytes tested per bank
	firstbank  = $01
	lastbank   = $7f	;every bank the 8 MB die covers

start	native
	short_a
	long_i
	ldx #str_hello
	jsr puts

	;; ---------------- fill ----------------
	ldx #str_fill
	jsr puts
	lda #firstbank
	sta curbank
fillbank lda curbank
	jsr puthex8
	lda #$20
	jsr putc
	lda curbank
	pha
	plb			;DBR = bank under test
	ldx #0
fillp	txa
	eor #$5a
	eor curbank		;bank-dependent: aliased banks would compare equal
	sta.w $0000,x		;.w forces abs,X -- see note below
	inx
	cpx #testlen
	bne fillp
	lda #$00
	pha
	plb			;back to bank 0 for strings
	inc curbank
	lda curbank
	cmp #lastbank+1
	bne fillbank

	;; ---------------- wait ----------------
	ldx #str_wait
	jsr puts
	jsr delay

	;; ---------------- verify ----------------
	ldx #str_check
	jsr puts
	lda #firstbank
	sta curbank
vfybank	lda curbank
	pha
	plb
	ldx #0
vfyp	txa
	eor #$5a
	eor curbank
	cmp.w $0000,x
	bne bad
	inx
	cpx #testlen
	bne vfyp
	lda #$00
	pha
	plb
	inc curbank
	lda curbank
	cmp #lastbank+1
	bne vfybank

	ldx #str_pass
	jsr puts
halt	bra halt

	;; ---------------- failure ----------------
bad	phx			;offset that miscompared
	lda curbank
	sta failbank
	lda #$00
	pha
	plb
	ldx #str_fail
	jsr puts
	lda failbank
	jsr puthex8
	lda #$3a		;':'
	jsr putc
	plx
	jsr puthex16
	ldx #str_crlf
	jsr puts
halt2	bra halt2

	;; -------------------------------------------------------------
	;; delay - roughly 4 seconds at 27 MHz
	;; inner loop is dex+bne = 3 cycles, 65536 times = ~197k cycles
	;; -------------------------------------------------------------
delay	ldy #$0220
dly0	ldx #0
dly1	dex
	bne dly1
	dey
	bne dly0
	rts

	;; -------------------------------------------------------------
	;; puts - print the null-terminated string at X (bank 0)
	;; -------------------------------------------------------------
puts	lda $0000,x
	beq puts_end
	jsr putc
	inx
	bra puts
puts_end rts

	;; putc - send A
putc	pha
putc0	lda ser_status
	and #$10
	beq putc0
	pla
	sta ser_data
	rts

	;; puthex16 - print X as four hex digits
puthex16 stx tmp
	lda tmp+1
	jsr puthex8
	lda tmp
	jsr puthex8
	rts

	;; puthex8 - print A as two hex digits
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

	;; -------------------------------------------------------------
str_hello text.0 "65C816 SDRAM test",$0d,$0a
str_fill  text.0 "fill banks: "
str_wait  text.0 $0d,$0a,"waiting (refresh test)... ",0
str_check text.0 "verifying... "
str_pass  text.0 "PASS",$0d,$0a
str_fail  text.0 "FAIL at "
str_crlf  text.0 $0d,$0a
