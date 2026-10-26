********************************************************************************
* romsize - a 16 KB boot ROM at $C000                                          *
*                                                                              *
* Its code starts at $C000, so it runs only if the ROM is sized to the image   *
* (tools/romimage.py). It checks:                                              *
*   1. $BFFF, just below the ROM, is RAM.                                      *
*   2. A write to $DF00 goes to the RAM underneath: $DF00 still reads ROM.     *
*   3. Copied into the RAM underneath and mapped out ($0300 = 0), it carries   *
*      on from RAM, and $DF00 reads what was written.                          *
* Prints "romsize: ok", or "romsize: fail" and the number of the check.       *
********************************************************************************

	include "mon-fixes/65816.asm"

	section "text"
	org=$c000

start	native
	short_a
	long_i
	jsr scc_init
	ldx #str_hello
	jsr puts

	;; ---- 1. RAM below the ROM ----
	lda #$5a
	sta $bfff
	lda $bfff
	cmp #$5a
	beq c2
	lda #1
	jmp fail

	;; ---- 2. a write under the ROM ----
c2	lda #$a5
	sta probe
	lda probe
	cmp #$ff		;the ROM's filler
	beq c3
	lda #2
	jmp fail

	;; ---- 3. into RAM, the ROM mapped out ----
c3	ldx #0
copy	lda $c000,x		;reads from the ROM, writes to the RAM under it
	sta $c000,x
	inx
	cpx #$0400		;the code; it is well under 1 KB
	bne copy
	lda #$a5
	sta probe		;again: a write, under the ROM
	stz $0300		;RAM from here on
	lda $0300
	bne bad3
	lda probe
	cmp #$a5
	beq allok
bad3	lda #3
	jmp fail

allok	ldx #str_ok
	jsr puts
	bra halt

	;; A holds the number of the check that failed
fail	pha
	ldx #str_fail
	jsr puts
	pla
	jsr puthex8
	ldx #str_crlf
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
	and #ser_txrdy
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

	include "scc.asm"

str_hello text.0 "romsize test",$0d,$0a
str_ok    text.0 "romsize: ok",$0d,$0a
str_fail  text.0 "romsize: fail "
str_crlf  text.0 $0d,$0a

	;; in the ROM's filler, past the code
	probe = $df00

	org=$fffc
	data.w start
	data.w start
