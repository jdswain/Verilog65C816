********************************************************************************
* romswitch - exercise the boot ROM / RAM soft switch at $0300                  *
*                                                                              *
* Reads of $E000-$FFFF come from block RAM while $0300 bit 0 is set; writes to  *
* that range always go to SDRAM. So the intended sequence is: copy the ROM      *
* into the RAM underneath itself, then clear the bit. Execution continues       *
* across the flip because both sides hold identical bytes.                      *
*                                                                              *
* $FF00 is used as the probe: it is past the end of the code, so the ROM image  *
* holds fill there and a different value can be written into the shadow.        *
********************************************************************************

	include "mon-fixes/65816.asm"

	section "text"
	org=$e000

	ser_base   = $0200
	ser_data   = ser_base + 0
	ser_status = ser_base + 1

	sys_ctrl   = $0300	;bit 0: 1 = ROM mapped at $E000, 0 = RAM
	probe      = $FF00	;spare location inside the ROM range

start	native
	short_a
	long_i
	ldx #str_hello
	jsr puts

	;; ---- what the switch reads as out of reset ----
	ldx #str_ctrl
	jsr puts
	lda sys_ctrl
	jsr puthex8
	jsr crlf

	;; ---- the ROM's own contents at the probe ----
	ldx #str_romval
	jsr puts
	lda probe
	jsr puthex8
	jsr crlf

	;; ---- shadow the whole 8 KB ROM into the RAM underneath ----
	;; Reads come from ROM, writes go to SDRAM, so this is a copy in place.
	ldx #0
shadow	lda.w $e000,x
	sta.w $e000,x
	inx
	cpx #$2000
	bne shadow

	;; ---- put a marker in the shadow only ----
	lda #$a5
	sta probe

	;; a read must STILL see the ROM: writes pass through, reads do not
	ldx #str_wrthru
	jsr puts
	lda probe
	jsr puthex8
	jsr crlf

	;; ---- flip to RAM.  Safe: the shadow is byte-identical here ----
	stz sys_ctrl
	ldx #str_ramval
	jsr puts
	lda probe
	jsr puthex8
	jsr crlf

	ldx #str_ctrl
	jsr puts
	lda sys_ctrl
	jsr puthex8
	jsr crlf

	;; ---- flip back to ROM ----
	lda #$01
	sta sys_ctrl
	ldx #str_back
	jsr puts
	lda probe
	jsr puthex8
	jsr crlf

	ldx #str_done
	jsr puts
halt	bra halt

crlf	ldx #str_crlf
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

str_hello  text.0 "ROM/RAM soft switch test",$0d,$0a
str_ctrl   text.0 "$0300 = "
str_romval text.0 "probe from ROM      = "
str_wrthru text.0 "probe after write   = "
str_ramval text.0 "probe with RAM in   = "
str_back   text.0 "probe with ROM back = "
str_done   text.0 "done",$0d,$0a
str_crlf   text.0 $0d,$0a

	;; Reset vector, and IRQ/BRK in emulation mode
	org=$fffc
	data.w start
	data.w start
