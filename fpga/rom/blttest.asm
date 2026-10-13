********************************************************************************
* blttest - exercise the blitter from the CPU                                  *
*                                                                              *
* Two self-checking tests, reported on the serial port, then a picture.        *
*                                                                              *
*   fill   The CPU writes a pattern and reads it back, so those bytes are in   *
*          its cache and the last of them is the cache's held word. The        *
*          blitter then fills over them. If the cache were not told, the CPU   *
*          would read its own stale pattern back instead of the fill.          *
*   copy   A copy to a destination that is byte-aligned but not word-aligned,  *
*          checked byte for byte.                                              *
*                                                                              *
* The picture, in graphics mode: a blue screen, sixteen colour bars, the bars  *
* copied lower down and shifted 13 pixels right, and copied again with black   *
* transparent so the blue shows through where the black bar was.               *
*                                                                              *
* Blitter addresses are in PIXELS: byte address * 2. The screen at $700000 is  *
* pixel $E00000, and pixel (x, y) is $E00000 + y*640 + x.                      *
********************************************************************************

	include "mon-fixes/65816.asm"

	section text
	org=$e000
	entry start

	ser_base   = $0200
	ser_data   = ser_base + 0
	ser_status = ser_base + 1

	vid_mode   = $0380

	blt_base   = $03c0
	blt_dst    = blt_base + $04
	blt_colour = blt_base + $11
	blt_ctrl   = blt_base + $12	;write bit 0 = start; read bit 7 = busy

	ptr        = $0010		;24 bit pointer to the test area
	count      = $0013
	bad        = $0014
	dstp       = $0018		;24 bit pixel address for the bars

	testbank   = $01		;test area: $010000, pixel $020000

start	native
	short_a
	long_i
	ldx #str_hello
	jsr puts

	stz ptr
	stz ptr+1
	lda #testbank
	sta ptr+2

	;; ---- fill over cached bytes ----
	ldx #str_fill
	jsr puts
	ldy #0
fill_w	tya			;pattern: byte n = n
	sta [ptr],y
	iny
	cpy #32
	bne fill_w
	ldy #0
fill_r	lda [ptr],y		;read it all back: now cached, last word held
	iny
	cpy #32
	bne fill_r
	ldx #blk_fill
	jsr blit
	stz bad
	ldy #31			;the held word first, then the rest
fill_c	lda [ptr],y
	cmp #$aa
	beq fill_ok
	inc bad
fill_ok	dey
	bpl fill_c
	jsr result

	;; ---- copy, destination not word aligned ----
	ldx #str_copy
	jsr puts
	ldy #$40
copy_w	tya			;source bytes $40..$5f hold their own offset
	sta [ptr],y
	iny
	cpy #$60
	bne copy_w
	ldy #$81
copy_z	lda #0			;clear the destination, and cache it
	sta [ptr],y
	lda [ptr],y
	iny
	cpy #$a1
	bne copy_z
	lda #$ff		;guard bytes either side of the destination
	ldy #$80
	sta [ptr],y
	ldy #$a1
	sta [ptr],y
	ldx #blk_copy
	jsr blit
	stz bad
	ldy #$81
	lda #$40
	sta count
copy_c	lda [ptr],y
	cmp count
	beq copy_ok
	inc bad
copy_ok	inc count
	iny
	cpy #$a1
	bne copy_c
	ldy #$80		;the guard bytes must be untouched
	lda [ptr],y
	cmp #$ff
	bne copy_e1
	ldy #$a1
	lda [ptr],y
	cmp #$ff
	beq copy_e2
copy_e1	inc bad
copy_e2	jsr result

	;; ---- the picture ----
	stz vid_mode		;graphics
	ldx #blk_clear
	jsr blit

	ldx #blk_bar		;bar 0, and the registers the rest share
	jsr blit
	lda #$00		;dstp = pixel address of bar 0
	sta dstp
	lda #$64
	sta dstp+1
	lda #$e0
	sta dstp+2
	lda #1
	sta count
bars	clc			;next bar is 40 pixels to the right
	lda dstp
	adc #40
	sta dstp
	sta blt_dst
	lda dstp+1
	adc #0
	sta dstp+1
	sta blt_dst+1
	lda dstp+2
	adc #0
	sta dstp+2
	sta blt_dst+2
	lda count
	sta blt_colour
	lda #$03		;fill, start
	sta blt_ctrl
	jsr blit_wait
	inc count
	lda count
	cmp #16
	bne bars

	ldx #blk_shift
	jsr blit
	ldx #blk_trans
	jsr blit

	ldx #str_done
	jsr puts
halt	bra halt

	;; Loads the 19 register bytes at X into the blitter, which starts it
	;; (the last is the control register), and waits for it to finish.
blit	ldy #0
blit0	lda $0000,x
	sta.w blt_base,y
	inx
	iny
	cpy #$13
	bne blit0
blit_wait lda blt_ctrl
	bmi blit_wait
	rts

	;; Prints "ok" or "FAIL" according to `bad`.
result	lda bad
	bne result1
	ldx #str_ok
	jmp puts
result1	ldx #str_fail
	jmp puts

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

	;; Register blocks: SRC(3) - DST(3) - SRC_STRIDE(2) DST_STRIDE(2)
	;; WIDTH(2) HEIGHT(2) OP COLOUR CONTROL

	;; Fill 32 bytes (64 pixels) at $010000 with colour $a: bytes become $aa.
blk_fill
	data.b $00,$00,$00,$00
	data.b $00,$00,$02,$00
	data.b $00,$00,$00,$00
	data.b 64,0,1,0
	data.b $03,$0a,$03

	;; Copy 32 bytes from $010040 to $010081: pixels $020080 -> $020102.
blk_copy
	data.b $80,$00,$02,$00
	data.b $02,$01,$02,$00
	data.b $00,$00,$00,$00
	data.b 64,0,1,0
	data.b $03,$00,$01

	;; The whole screen, colour 1.
blk_clear
	data.b $00,$00,$00,$00
	data.b $00,$00,$e0,$00
	data.b $80,$02,$80,$02
	data.b $80,$02,$e0,$01
	data.b $03,$01,$03

	;; Bar 0: 40 x 100 at (0, 40), colour 0. Pixel $E00000 + 40*640 = $E06400.
blk_bar
	data.b $00,$00,$00,$00
	data.b $00,$64,$e0,$00
	data.b $80,$02,$80,$02
	data.b 40,0,100,0
	data.b $03,$00,$03

	;; The bars, 600 wide, copied to (13, 200): $E00000 + 200*640 + 13 = $E1F40D.
blk_shift
	data.b $00,$64,$e0,$00
	data.b $0d,$f4,$e1,$00
	data.b $80,$02,$80,$02
	data.b $58,$02,100,0
	data.b $03,$00,$01

	;; And again to (0, 340) = $E35200, with colour 0 transparent.
blk_trans
	data.b $00,$64,$e0,$00
	data.b $00,$52,$e3,$00
	data.b $80,$02,$80,$02
	data.b $80,$02,100,0
	data.b $03,$00,$05

str_hello text.0 "blitter test",$0d,$0a
str_fill  text.0 "fill over cached bytes: "
str_copy  text.0 "unaligned copy: "
str_ok    text.0 "ok",$0d,$0a
str_fail  text.0 "FAIL",$0d,$0a
str_done  text.0 "picture drawn",$0d,$0a
