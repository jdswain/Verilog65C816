********************************************************************************
* texttest - exercise the 80x30 text mode                                      *
*                                                                              *
* Text lives where the graphics frame does, at $700000: 30 rows of 80 cells,   *
* two bytes per cell -- the character, then an attribute whose low nibble is   *
* the foreground colour and high nibble the background. A row is 160 bytes.    *
*                                                                              *
* The screen it draws:                                                         *
*   row 0       a title bar, white on blue                                     *
*   rows 2-9    all 256 glyphs of the font, 32 to a row                        *
*   rows 12-27  one line in each of the 16 foreground colours, and a swatch    *
*               of the same colour as a background                             *
*   row 29      a footer                                                       *
* Anything wrong with the cell layout, the attribute nibbles, the row address  *
* or the font's glyph order shows up somewhere in that.                        *
********************************************************************************

	include "mon-fixes/65816.asm"

	section "text"
	org=$e000

	ser_base   = $0200
	ser_data   = ser_base + 0
	ser_status = ser_base + 1

	vid_mode   = $0380		;bit 0: 1 = text

	ptr        = $0010		;24-bit pointer to the screen; Y is the offset
	attr       = $0013		;attribute used by putcell
	count      = $0014
	tmp        = $0015
	rowoff     = $0016		;16-bit offset of the row being drawn

	rowbytes   = 160
	scrbytes   = 30*rowbytes

start	native
	short_a
	long_i
	stz ptr
	stz ptr+1
	lda #$70
	sta ptr+2

	;; ---- clear to grey-on-black spaces ----
	lda #$07
	sta attr
	ldy #0
clear	lda #$20
	jsr putcell
	cpy #scrbytes
	bne clear

	;; ---- title bar ----
	lda #$1f		;white on blue
	sta attr
	ldy #0
tbar	lda #$20
	jsr putcell
	cpy #rowbytes
	bne tbar
	ldy #2*2
	ldx #str_title
	jsr vputs

	;; ---- the whole font, 32 glyphs to a row with a gap between them ----
	lda #$0f		;white on black
	sta attr
	stz count
	long_a
	lda #2*rowbytes+8*2
	sta rowoff
	short_a
fontrow	ldy rowoff
fontcol	lda count
	jsr putcell
	iny			;leave the next cell blank
	iny
	inc count
	lda count
	and #$1f
	bne fontcol
	jsr nextrow
	lda count		;wrapped to 0 after glyph 255
	bne fontrow

	;; ---- sixteen colours ----
	stz count
	long_a
	lda #12*rowbytes+2*2
	sta rowoff
	short_a
colrow	lda count
	bne colfg
	lda #$70		;colour 0 is black: show it on grey instead
colfg	sta attr
	ldy rowoff
	ldx #str_fox
	jsr vputs
	lda count		;swatch: the same colour as a background
	asl a
	asl a
	asl a
	asl a
	sta attr
	iny
	iny
	lda #8
	sta tmp
swatch	lda #$20
	jsr putcell
	dec tmp
	bne swatch
	jsr nextrow
	inc count
	lda count
	cmp #16
	bne colrow

	;; ---- footer ----
	lda #$0e		;yellow on black
	sta attr
	ldy #29*rowbytes+2*2
	ldx #str_foot
	jsr vputs

	lda #1
	sta vid_mode		;switch to text

	ldx #str_done
	jsr puts
halt	bra halt

	;; Write the character in A, with the current attribute, at offset Y.
putcell	sta [ptr],y
	iny
	lda attr
	sta [ptr],y
	iny
	rts

	;; Write the string at X to the screen at offset Y.
vputs	lda $0000,x
	beq vputs_end
	jsr putcell
	inx
	bra vputs
vputs_end rts

nextrow	long_a
	lda rowoff
	clc
	adc #rowbytes
	sta rowoff
	short_a
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

str_title text.0 "65C816 SoC on the Tang Nano 20K -- 80 x 30 text, Atari ST 8x16 font"
str_fox   text.0 "The quick brown fox jumps over the lazy dog 0123456789"
str_foot  text.0 "Character at even address, attribute at odd: low nibble ink, high nibble paper."
str_done  text.0 "text mode on",$0d,$0a

	;; Reset vector, and IRQ/BRK in emulation mode
	org=$fffc
	data.w start
	data.w start
