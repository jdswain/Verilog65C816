********************************************************************************
* maptest - verify the bank 0 memory map                                       *
*                                                                              *
* memtest covers banks $01-$7F and deliberately skips bank 0, which is the one  *
* bank with holes in it. This checks the holes are where they should be:        *
*                                                                              *
*   $0000-$01FF  RAM   zero page and stack -- must NOT be decoded as I/O        *
*   $0200-$0FFF  I/O   must NOT behave as RAM                                   *
*   $1000-$DEFF  RAM   main memory                                              *
*   $DF00-$DFFF  RAM   reserved here for this program's stack and variables     *
*   $E000-$FFFF  ROM   reads must ignore writes while $0300 bit 0 is set        *
*                                                                              *
* The RAM patterns fold in both halves of the address, so a decode that aliased *
* one page onto another would be caught rather than comparing equal.            *
********************************************************************************

	include "mon-fixes/65816.asm"

	section "text"
	org=$e000

	ser_base   = $0200
	ser_data   = ser_base + 0
	ser_status = ser_base + 1
	sys_ctrl   = $0300

	;; Scratch, in the block reserved below the stack. Absolute, not direct
	;; page: direct page is $0000-$00FF and is one of the regions under test.
	tmpa       = $DF00
	expect     = $DF01
	got        = $DF02
	errs       = $DF03
	errs0      = $DF04	;errs at the end of the previous region
	tag        = $DF05	;region tag folded into the pattern

start	native
	short_a
	long_i
	ldx #$dfff		;stack out of every region under test
	txs

	ldx #str_hello
	jsr puts
	stz errs
	stz errs0

	;; ---- region 1: $0000-$01FF, zero page and stack ----
	ldx #str_r1
	jsr puts
	lda #$01
	sta tag
	jsr fill_lo
	jsr ver_lo

	;; ---- region 2: $1000-$DEFF, main memory ----
	ldx #str_r2
	jsr puts
	lda #$02
	sta tag
	jsr fill_hi
	jsr ver_hi

	;; ---- region 3: the I/O block must not be RAM ----
	;; $0400 is inside the window but unclaimed, so it reads $FF whatever
	;; was written to it. If it stored, the I/O hole is really SDRAM.
	ldx #str_r3
	jsr puts
	lda #$a5
	sta $0400
	lda #$5a
	sta $0780
	lda #$ff
	sta expect
	lda $0400
	jsr expect8
	lda $0780
	jsr expect8
	jsr endline

	;; ---- region 4: ROM reads ignore writes ----
	ldx #str_r4
	jsr puts
	lda $e000
	sta expect		;whatever the ROM holds
	eor #$ff
	sta $e000		;goes to the SDRAM underneath
	lda $e000		;must still be the ROM byte
	jsr expect8
	lda $ffff		;the far end of the ROM too
	sta expect
	eor #$ff
	sta $ffff
	lda $ffff
	jsr expect8
	jsr endline

	;; ---- verdict ----
	lda errs
	beq allgood
	ldx #str_fail
	jsr puts
	lda errs
	jsr puthex8
	jsr crlf
	bra halt
allgood	ldx #str_pass
	jsr puts
halt	bra halt

;;; ---- $0000-$01FF ------------------------------------------------------
fill_lo	ldx #0
fl0	jsr patt
	sta.w $0000,x
	inx
	cpx #$0200
	bne fl0
	rts

ver_lo	ldx #0
vl0	jsr patt
	sta expect
	lda.w $0000,x
	jsr expect8
	inx
	cpx #$0200
	bne vl0
	jmp endline

;;; ---- $1000-$DEFF ------------------------------------------------------
fill_hi	ldx #0
fh0	jsr patt
	sta.w $1000,x
	inx
	cpx #$cf00
	bne fh0
	rts

ver_hi	ldx #0
vh0	jsr patt
	sta expect
	lda.w $1000,x
	jsr expect8
	inx
	cpx #$cf00
	bne vh0
	jmp endline

;;; Pattern from BOTH halves of the index plus the region tag in Y, so a
;;; decode that folded one page onto another would not compare equal.
patt	rep #$20
	txa
	sep #$20
	sta tmpa		;low byte of X
	xba			;high byte of X
	eor tmpa
	eor tag
	rts

;;; Compare A against `expect`; count and report a mismatch.  Only the first
;;; few are printed -- a broken region would otherwise emit 53k lines.
expect8	sta got
	cmp expect
	beq exp_ok
	lda errs
	cmp #$08
	bcs exp_cnt
	pha
	lda #$20
	jsr putc
	lda #$3c		;'<'
	jsr putc
	rep #$20
	txa
	sep #$20
	xba
	jsr puthex8
	rep #$20
	txa
	sep #$20
	jsr puthex8
	lda #$3a		;':'
	jsr putc
	lda got
	jsr puthex8
	lda #$2f		;'/'
	jsr putc
	lda expect
	jsr puthex8
	lda #$3e		;'>'
	jsr putc
	pla
exp_cnt	inc errs
exp_ok	rts

;;; ---- console ----------------------------------------------------------
endline	lda errs
	cmp errs0
	beq el_ok
	sta errs0
	ldx #str_bad
	bra puts
el_ok	ldx #str_ok
	bra puts

crlf	ldx #str_crlf
puts	lda.w $0000,x
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

str_hello text.0 "bank 0 map test",$0d,$0a
str_r1    text.0 "$0000-$01FF RAM  "
str_r2    text.0 "$1000-$DEFF RAM  "
str_r3    text.0 "$0200-$0FFF I/O  "
str_r4    text.0 "$E000-$FFFF ROM  "
str_ok    text.0 "ok",$0d,$0a
str_bad   text.0 "BAD",$0d,$0a
str_pass  text.0 "PASS",$0d,$0a
str_fail  text.0 "FAIL, errors=",$00
str_crlf  text.0 $0d,$0a

	;; Reset vector, and IRQ/BRK in emulation mode
	org=$fffc
	data.w start
	data.w start
