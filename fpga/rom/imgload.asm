********************************************************************************
* imgload - receive a picture over the serial port and show it                 *
*                                                                              *
* The image is far too big for the 8 KB ROM (150 KB), so it is sent from the   *
* host: tools/mkimage.py builds the file and `board.py load` sends it.         *
*                                                                              *
* Protocol, after the ROM prints "ready":                                      *
*   64 bytes      palette, written straight to $0240-$027F                     *
*   153600 bytes  framebuffer, written to $700000-$7257FF                      *
* The ROM then prints "sum=XXXX", the 16-bit sum of all 153664 bytes, which    *
* the host compares with its own. There is no flow control: one byte costs     *
* about 2190 clocks at 115200 baud and the loop below takes well under 100.    *
*                                                                              *
* The framebuffer is written through a 24-bit pointer in the direct page, not  *
* by moving DBR, because the loop also has to reach the ACIA in bank 0.        *
********************************************************************************

	include "mon-fixes/65816.asm"

	section text
	org=$e000
	entry start

	ser_base   = $0200
	ser_data   = ser_base + 0
	ser_status = ser_base + 1

	pal_base   = $0240

	ptr        = $0010		;24-bit framebuffer pointer (low word stays 0)
	sum        = $0014		;16-bit checksum

	fbfirst    = $70
	fblast     = $72
	fbtail     = $5800		;bytes used in the last bank

start	native
	short_a
	long_i
	stz sum
	stz sum+1
	stz ptr
	stz ptr+1
	lda #fbfirst
	sta ptr+2
	ldx #str_ready
	jsr puts

	;; ---- palette: 64 bytes ----
	ldx #0
palloop	jsr getc
	sta.w pal_base,x
	inx
	cpx #64
	bne palloop

	;; ---- framebuffer ----
	ldy #0
fbloop	jsr getc
	sta [ptr],y
	iny
	bne fbchk
	inc ptr+2		;Y wrapped: next bank
fbchk	lda ptr+2
	cmp #fblast
	bne fbloop
	cpy #fbtail
	bne fbloop

	ldx #str_sum
	jsr puts
	lda sum+1
	jsr puthex8
	lda sum
	jsr puthex8
	ldx #str_crlf
	jsr puts
halt	bra halt

	;; Wait for a byte, add it to the checksum, return it in A.
getc	lda ser_status
	and #$08
	beq getc
	lda ser_data
	pha
	clc
	adc sum
	sta sum
	bcc getc_end
	inc sum+1
getc_end pla
	rts

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


str_ready text.0 "ready",$0d,$0a
str_sum   text.0 "sum="
str_crlf  text.0 $0d,$0a
