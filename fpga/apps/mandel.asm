********************************************************************************
* mandel - a Mandelbrot set viewer in the 640x480 16-colour graphics mode      *
*                                                                              *
* Loaded at $2000 with MiniMon's ld and started with "go 2000" (make mandel-   *
* load does both). Keys, from the ADB keyboard or the serial port:             *
*                                                                              *
*   arrows or W A S D   move a quarter of the screen                           *
*   + (or =)  -         zoom in, out, by two                                   *
*   > (or .)  < (or ,)  more, fewer iterations (32 to 512, in 32s)             *
*   R                   back to the whole set                                  *
*   Q                   back to MiniMon, in text mode                          *
*                                                                              *
* A key takes effect at the start of the next line, and the picture is drawn   *
* again from the top; the old one stays until it is drawn over.                *
*                                                                              *
* There is no multiplier, so the arithmetic is done with squares from a        *
* table. Numbers are 16 bit fixed point with 13 fraction bits (-4 to +4).      *
* Escaping is decided before anything can overflow: |x| or |y| at 2 or more,   *
* x^2 + y^2 at 4 or more, or the next x or y leaving the range. Every square   *
* is then of something below 2 -- 16384 entries -- and                          *
*                                                                              *
*   2xy = 4 * ((x + y) / 2)^2 - x^2 - y^2                                      *
*                                                                              *
* is exact modulo 2^16, because the true result lies within +/-4. With 13      *
* fraction bits the step between pixels is at least 1/8192, so zooming stops   *
* about five times in from the whole set.                                      *
********************************************************************************

	include "../rom/mon-fixes/65816.asm"

	section "text"
	org=$2000

	sq        = $4000		;the table: (i*i) >> 13 for i < 16384, 32 KB
	dpage     = $3F00		;our direct page

	screen    = $700000
	vid_mode  = $0380		;bit 0: 1 = text
	palette   = $0240		;16 x {r, g, b, -}
	scc_ctl   = $0822		;channel A control: RR0
	scc_data  = $0823
	adb_cmd   = $0280
	adb_status = $0281		;busy, done, timeout, srq, count[3:0]
	adb_ctrl  = $0283		;read: bit 0 = collision
	adb_data  = $0288
	mm_conpos = $004A		;MiniMon: offset of its cursor cell

	;; Direct page
	zx        = $00		;z, the point being iterated
	zy        = $02
	cx        = $04		;c, the pixel
	cy        = $06
	x2        = $08		;zx^2, zy^2
	y2        = $0A
	cnt       = $0C		;iterations left
	step      = $0E		;between pixels
	cenx      = $10		;the centre of the screen
	ceny      = $12
	x0        = $14		;cx at the left edge
	maxit     = $16
	ptr       = $18		;24 bit: the line being drawn
	pix       = $1C		;the left pixel of a pair
	t0        = $1E
	t1        = $20
	sv_cenx   = $22		;the view before a command, to undo it
	sv_ceny   = $24
	sv_step   = $26
	sv_maxit  = $28
	escst     = $2A		;serial: 1 after ESC, 2 after ESC [
	kbd_busy  = $2C		;an ADB poll is in flight
	kbd_next  = $2E		;second event of a packet, $FF if none
	row       = $30

	;; Commands
	C_UP = 1
	C_DOWN = 2
	C_LEFT = 3
	C_RIGHT = 4
	C_IN = 5
	C_OUT = 6
	C_MORE = 7
	C_FEWER = 8
	C_RESET = 9
	C_QUIT = 10

	longa = off
	longi = on

;;; Entered by MiniMon's go: native, A 8 bit, X and Y 16 bit, a long call.
start	php
	phb
	phd
	rep #$20
	longa = on
	lda #dpage
	tcd
	sep #$20
	longa = off
	lda #0
	pha
	plb			;data bank 0
	ldx #str_help
	jsr puts
	jsr mksq
	jsr setpal
	stz vid_mode		;graphics
	rep #$30
	longa = on
	stz escst		;all 16 bit, high bytes 0
	stz kbd_busy
	lda #$00FF
	sta kbd_next
	jsr reset
	;; Draw, then wait for a key; a key during drawing starts again.
redraw	jsr draw
	bcs command		;interrupted
idle	jsr getcmd
	beq idle
command	jsr apply
	bcc redraw
	jmp quit

;;; ---- the square table --------------------------------------------------
;;; s = i*i kept as 32 bits in t0/t1, stepping by 2i+1; each entry is s >> 13.
	longa = off
mksq	rep #$30
	longa = on
	stz t0
	stz t1
	ldx #0
mksq0	lda t0			;s >> 13 = (s >> 16) << 3 | (s & $FFFF) >> 13
	xba
	lsr a
	lsr a
	lsr a
	lsr a
	lsr a
	and #$0007
	sta pix
	lda t1
	asl a
	asl a
	asl a
	ora pix
	sta sq,x
	txa			;s += 2i + 1, where i = x / 2
	clc
	adc #1
	adc t0
	sta t0
	bcc mksq1
	inc t1
mksq1	inx
	inx
	cpx #$8000
	bne mksq0
	sep #$20
	longa = off
	rts

;;; ---- palette -----------------------------------------------------------
setpal	ldx #0
	ldy #0
setpal0	lda pal_mandel,x
	sta palette,y
	lda pal_mandel+1,x
	sta palette+1,y
	lda pal_mandel+2,x
	sta palette+2,y
	inx
	inx
	inx
	iny
	iny
	iny
	iny
	cpy #64
	bne setpal0
	rts

;;; Back to MiniMon's: the default palette, text mode, a blank screen.
pal_default
	ldx #0
	ldy #0
paldef0	lda pal_cga,x
	sta palette,y
	lda pal_cga+1,x
	sta palette+1,y
	lda pal_cga+2,x
	sta palette+2,y
	inx
	inx
	inx
	iny
	iny
	iny
	iny
	cpy #64
	bne paldef0
	rts

;;; ---- drawing -----------------------------------------------------------
;;; With A, X and Y all 16 bit. Returns carry set and a command in A if a key
;;; interrupted it, carry clear when the picture is finished.
	longa = on
draw	lda step		;x0 = cenx - 320 * step
	xba
	and #$FF00
	sta t0
	lda step
	asl a
	asl a
	asl a
	asl a
	asl a
	asl a
	clc
	adc t0
	sta t0
	lda cenx
	sec
	sbc t0
	sta x0
	lda step		;cy = ceny - 240 * step
	xba
	and #$FF00
	sta t0
	lda step
	asl a
	asl a
	asl a
	asl a
	sta t1
	lda t0
	sec
	sbc t1
	sta t0
	lda ceny
	sec
	sbc t0
	sta cy
	lda #screen&$FFFF
	sta ptr
	lda #screen>>16
	sta ptr+2		;and ptr+3, which nothing uses
	stz row
draw_row
	jsr getcmd
	beq draw_go
	sec
	rts
draw_go	lda x0
	sta cx
	ldy #0
draw_px	jsr point		;left pixel
	sta pix
	lda cx
	clc
	adc step
	sta cx
	jsr point		;right pixel, in the high nibble
	asl a
	asl a
	asl a
	asl a
	ora pix
	sep #$20
	longa = off
	sta [ptr],y
	rep #$20
	longa = on
	lda cx
	clc
	adc step
	sta cx
	iny
	cpy #320
	bne draw_px
	lda ptr			;next line: 320 bytes on
	clc
	adc #320
	sta ptr
	bcc draw_nx
	inc ptr+2
draw_nx	lda cy
	clc
	adc step
	sta cy
	inc row
	lda row
	cmp #480
	bne draw_row
	clc
	rts

;;; The colour of the point c = (cx, cy): 0 inside the set, 1-15 by how soon
;;; it escaped. A and X 16 bit; Y is kept.
point	lda cx
	sta zx
	lda cy
	sta zy
	lda maxit
	sta cnt
iter	lda zx
	bpl iter_xp
	eor #$FFFF
	inc a
iter_xp	cmp #$4000		;|x| >= 2: escaped
	bcs escaped
	asl a
	tax
	lda sq,x
	sta x2
	lda zy
	bpl iter_yp
	eor #$FFFF
	inc a
iter_yp	cmp #$4000
	bcs escaped
	asl a
	tax
	lda sq,x
	sta y2
	clc
	adc x2			;x^2 + y^2 >= 4: escaped
	bmi escaped
	lda zx			;s = (x + y) / 2, which is below 2
	clc
	adc zy
	cmp #$8000
	ror a
	bpl iter_sp
	eor #$FFFF
	inc a
iter_sp	asl a
	tax
	lda sq,x		;2xy = 4 s^2 - x^2 - y^2, modulo 2^16
	asl a
	asl a
	sec
	sbc x2
	sec
	sbc y2
	clc
	adc cy			;y = 2xy + cy
	bvs escaped
	sta zy
	lda x2			;x = x^2 - y^2 + cx
	sec
	sbc y2
	clc
	adc cx
	bvs escaped
	sta zx
	dec cnt
	bne iter
	lda #0			;never escaped: inside
	rts
escaped	lda maxit		;colour by the iterations it took
	sec
	sbc cnt
	and #$003F
	tax
	lda colours,x
	and #$000F
	rts

;;; ---- commands ----------------------------------------------------------
;;; A command in A (16 bit). Returns carry set to quit.
apply	cmp #C_QUIT
	bne apply1
	sec
	rts
apply1	ldx cenx
	stx sv_cenx
	ldx ceny
	stx sv_ceny
	ldx step
	stx sv_step
	ldx maxit
	stx sv_maxit
	asl a
	tax
	jsr (cmd_tab-2,x)
	jsr inrange		;a view off the edge of the numbers is undone
	bcc apply9
	lda sv_cenx
	sta cenx
	lda sv_ceny
	sta ceny
	lda sv_step
	sta step
	lda sv_maxit
	sta maxit
apply9	clc
	rts

cmd_tab	data.w do_up, do_down, do_left, do_right, do_in, do_out
	data.w do_more, do_fewer, reset

do_up	jsr quarter_v
	eor #$FFFF
	inc a
	bra move_v
do_down	jsr quarter_v
move_v	clc
	adc ceny
	sta ceny
	rts
do_left	jsr quarter_h
	eor #$FFFF
	inc a
	bra move_h
do_right jsr quarter_h
move_h	clc
	adc cenx
	sta cenx
	rts
quarter_h lda step		;160 * step
	xba
	and #$FF00
	lsr a
	sta t0
	lda step
	asl a
	asl a
	asl a
	asl a
	asl a
	clc
	adc t0
	rts
quarter_v lda step		;120 * step
	asl a
	asl a
	asl a
	sta t0
	asl a
	asl a
	asl a
	asl a
	sec
	sbc t0
	rts
do_in	lda step
	cmp #2
	bcc do_rts		;a step of 1 is as far as it goes
	lsr a
	sta step
do_rts	rts
do_out	asl step
	rts
do_more	lda maxit
	cmp #512
	bcs do_rts
	adc #32
	sta maxit
	rts
do_fewer lda maxit
	cmp #33
	bcc do_rts
	sbc #32
	sta maxit
	rts
reset	lda #$E800		;centre (-0.75, 0)
	sta cenx
	stz ceny
	lda #44			;640 pixels = 3.44
	sta step
	lda #32
	sta maxit
	rts

;;; Carry set if the view would reach past +/-4: |cenx| + 320 * step and
;;; |ceny| + 240 * step must both stay below $8000.
inrange	lda step
	cmp #128
	bcs inr_bad
	xba
	and #$FF00
	sta t0
	lda step
	asl a
	asl a
	asl a
	asl a
	asl a
	asl a
	clc
	adc t0			;320 * step
	sta t0
	lda cenx
	bpl inr_x
	eor #$FFFF
	inc a
inr_x	clc
	adc t0
	bcs inr_bad
	bmi inr_bad
	lda step
	asl a
	asl a
	asl a
	asl a
	sta t1			;16 * step
	lda t0
	sec
	sbc t1
	sbc t1
	sbc t1
	sbc t1
	sbc t1			;240 * step = 320 * step - 80 * step
	sta t0
	lda ceny
	bpl inr_y
	eor #$FFFF
	inc a
inr_y	clc
	adc t0
	bcs inr_bad
	bmi inr_bad
	clc
	rts
inr_bad	sec
	rts

;;; ---- keys --------------------------------------------------------------
;;; A command from the serial port or the keyboard in A, or 0 (Z set) if
;;; there is none. Never waits. 16 bit A and X.
getcmd	sep #$20
	longa = off
	lda scc_ctl
	and #$01
	beq getcmd_k
	lda scc_data
	jsr sercmd
	bra getcmd9
getcmd_k jsr kbd_get
	bcc getcmd_n
	jsr idx_a
	lda adb_cmds,x
	bra getcmd9
getcmd_n lda #0
getcmd9	rep #$20
	longa = on
	and #$00FF
	rts

;;; A serial character in A (8 bit) -> a command or 0. VT100 arrows come as
;;; ESC [ A to D.
	longa = off
sercmd	ldx escst
	beq ser_plain
	cpx #1
	bne ser_seq
	cmp #'['
	bne ser_none
	ldx #2
	stx escst
	lda #0
	rts
ser_seq	stz escst
	stz escst+1
	sec
	sbc #'A'
	cmp #4
	bcs ser_zero
	jsr idx_a
	lda arrows,x
	rts
ser_plain cmp #$1B
	bne ser_tab
	ldx #1
	stx escst
	lda #0
	rts
ser_tab	ora #$20		;letters either case
	ldx #0
ser_find ldy ser_keys,x
	beq ser_zero
	cmp ser_keys,x
	beq ser_hit
	inx
	inx
	bra ser_find
ser_hit	lda ser_keys+1,x
	rts
ser_none stz escst
	stz escst+1
ser_zero lda #0
	rts

;;; X = A (8 bit) with no high byte: TAX copies all 16 bits of C.
idx_a	xba
	lda #0
	xba
	tax
	rts

arrows	data.b C_UP, C_DOWN, C_RIGHT, C_LEFT
;;; character (or'd with $20), command; 0 ends it
ser_keys data.b 'w', C_UP, 's', C_DOWN, 'a', C_LEFT, 'd', C_RIGHT
	data.b '+'|$20, C_IN, '=', C_IN, '-', C_OUT
	data.b '>'|$20, C_MORE, '.', C_MORE, '<'|$20, C_FEWER, ',', C_FEWER
	data.b 'r', C_RESET, 'q', C_QUIT, 0, 0

;;; A key going down on the ADB keyboard: carry set and its key code in A
;;; (16 bit X, 8 bit A), else carry clear. Never waits: a poll in flight is
;;; collected by a later call. Only clean two-byte answers count.
kbd_get	lda kbd_next
	cmp #$FF
	beq kbd_poll
	ldx #$FF
	stx kbd_next
	bra kbd_ev
kbd_poll lda adb_status
	bmi kbd_no		;a poll is in flight
	lda kbd_busy
	beq kbd_start
	stz kbd_busy
	lda adb_status
	and #$6F
	cmp #$42		;done, no timeout, two bytes
	bne kbd_start
	lda adb_ctrl
	and #$01		;collision
	bne kbd_start
	lda adb_data+1
	sta kbd_next
	lda adb_data
kbd_ev	bit #$80		;key up, or no event
	bne kbd_no
	sec
	rts
kbd_start lda #$2C		;Talk register 0, device 2
	sta adb_cmd
	lda #1
	sta kbd_busy
kbd_no	clc
	rts

;;; ---- leaving -----------------------------------------------------------
	longa = on
quit	sep #$20
	longa = off
	jsr pal_default
	lda #1
	sta vid_mode
	;; Blank the text screen. MiniMon marks its cursor by inverting a cell's
	;; attribute and inverts it back before printing, so that cell is left
	;; inverted for it.
	rep #$20
	longa = on
	lda #$0720
	ldx #0
quit0	sta.l screen,x
	inx
	inx
	cpx #4800
	bne quit0
	lda.l mm_conpos		;bank 0, not our direct page
	tax
	lda #$7020
	sta.l screen,x
	sep #$20
	longa = off
	ldx #str_bye
	jsr puts
	pld
	plb
	plp
	rtl

;;; ---- serial output -----------------------------------------------------
puts	lda.w $0000,x
	beq puts9
puts0	pha
puts1	lda scc_ctl
	and #$04		;transmit buffer empty
	beq puts1
	pla
	sta scc_data
	inx
	bra puts
puts9	rts

;;; ---- data --------------------------------------------------------------
;;; Escape colours, by iterations taken (mod 64): 1-15 cycled, never 0.
colours	data.b 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
	data.b 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
	data.b 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
	data.b 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
	data.b 1,2,3,4

;;; ADB key code -> command (key codes $00-$7F)
adb_cmds data.b C_LEFT,C_DOWN,C_RIGHT,0,0,0,0,0		;$00 a s d
	data.b 0,0,0,0,C_QUIT,C_UP,0,C_RESET		;$08 q w r
	data.b 0,0,0,0,0,0,0,0				;$10
	data.b C_IN,0,0,C_OUT,0,0,0,0			;$18 = -
	data.b 0,0,0,0,0,0,0,0				;$20
	data.b 0,0,0,C_FEWER,0,0,0,C_MORE		;$28 , .
	data.b 0,0,0,0,0,0,0,0				;$30
	data.b 0,0,0,C_LEFT,C_RIGHT,C_DOWN,C_UP,0	;$38 arrows
	data.b 0,0,0,0,0,C_IN,0,0			;$40 keypad +
	data.b 0,0,0,0,0,0,C_OUT,0			;$48 keypad -
	data.b 0,0,0,0,0,0,0,0				;$50
	data.b 0,0,0,0,0,0,0,0				;$58
	data.b 0,0,0,0,0,0,0,0				;$60
	data.b 0,0,0,0,0,0,0,0				;$68
	data.b 0,0,0,0,0,0,0,0				;$70
	data.b 0,0,0,0,0,0,0,0				;$78

;;; Black inside; outside, dark blue through cyan and white to gold and red.
pal_mandel
	data.b $00,$00,$00, $00,$00,$40, $00,$00,$80, $00,$20,$C0
	data.b $00,$50,$FF, $00,$90,$FF, $00,$C8,$FF, $40,$F0,$FF
	data.b $A0,$FF,$FF, $FF,$FF,$FF, $FF,$F0,$A0, $FF,$D0,$40
	data.b $FF,$A0,$00, $FF,$60,$00, $D0,$20,$00, $80,$00,$40

;;; The power-on palette, as in rtl/video.v
pal_cga	data.b $00,$00,$00, $00,$00,$AA, $00,$AA,$00, $00,$AA,$AA
	data.b $AA,$00,$00, $AA,$00,$AA, $AA,$55,$00, $AA,$AA,$AA
	data.b $55,$55,$55, $55,$55,$FF, $55,$FF,$55, $55,$FF,$FF
	data.b $FF,$55,$55, $FF,$55,$FF, $FF,$FF,$55, $FF,$FF,$FF

str_help text.0 "Mandelbrot: arrows/WASD move, + - zoom, < > iterations, R reset, Q quit",$0d,$0a
str_bye	text.0 "mandel done",$0d,$0a
