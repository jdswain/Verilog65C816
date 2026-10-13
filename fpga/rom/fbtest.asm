********************************************************************************
* fbtest - fill the 640x480 4bpp framebuffer with a test pattern               *
*                                                                              *
* The framebuffer is 320 bytes per line x 480 lines = 150 KB at $700000, so it *
* spans banks $70..$72. Each byte holds two pixels, low nibble first.          *
*                                                                              *
* Byte value = low byte of the address, which gives a regular repeating ramp   *
* across each line: obviously wrong if anything about the fetch, the line      *
* buffer or the nibble ordering is broken.                                     *
********************************************************************************

	include "mon-fixes/65816.asm"

	section text
	org=$e000
	entry start

	ser_base   = $0200
	ser_data   = ser_base + 0
	ser_status = ser_base + 1

	curbank    = $0012
	palidx     = $0013

	;; Palette: 16 entries x 4 bytes {red, green, blue, unused}
	pal_base   = $0240

	fbfirst    = $70
	fblast     = $72

start	native
	short_a
	long_i
	ldx #str_hello
	jsr puts

	;; ---- load a greyscale ramp into the palette ----
	;; Entry n gets red=green=blue=n*17, so a correct palette port shows a
	;; smooth black-to-white ramp instead of the default colour set.
	ldx #str_pal
	jsr puts
	lda #0
	sta palidx
palloop	lda palidx
	asl a			;index*2
	asl a			;index*4 = byte offset of the entry
	tay
	lda palidx
	asl a
	asl a
	asl a
	asl a
	clc
	adc palidx
	;; A now holds the grey level; write it to R, G and B
	sta.w pal_base,y
	iny
	sta.w pal_base,y
	iny
	sta.w pal_base,y
	inc palidx
	lda palidx
	cmp #16
	bne palloop

	lda #fbfirst
	sta curbank
fbbank	lda curbank
	jsr puthex8
	lda #$20
	jsr putc
	lda curbank
	pha
	plb			;DBR = framebuffer bank
	ldx #0
fbfill	txa			;byte = low byte of the address
	sta.w $0000,x		;.w forces abs,X (DBR relative)
	inx
	bne fbfill		;X is 16 bits: wraps after $FFFF
	lda #$00
	pha
	plb
	inc curbank
	lda curbank
	cmp #fblast+1
	bne fbbank

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


str_pal   text.0 "palette ramp, "
str_hello text.0 "framebuffer fill: "
str_done  text.0 "done",$0d,$0a
