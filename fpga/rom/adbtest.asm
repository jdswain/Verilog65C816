********************************************************************************
* adbtest - exercise the Apple Desktop Bus host controller                     *
*                                                                              *
* With no device attached, a Talk should complete with the timeout bit set:    *
* that alone proves the register interface, the command trigger, the bit        *
* transmitter and the Tlt timeout are all working. With a keyboard attached,    *
* the same command should return data instead.                                 *
********************************************************************************

	include "mon-fixes/65816.asm"

	section "text"
	org=$e000

	ser_base   = $0200
	ser_data   = ser_base + 0
	ser_status = ser_base + 1

	;; ADB host registers
	adb_base   = $0280
	adb_cmd    = adb_base + 0
	adb_status = adb_base + 1
	adb_len    = adb_base + 2
	adb_ctrl   = adb_base + 3
	adb_data   = adb_base + 8

	tmp        = $0010

start	native
	short_a
	long_i
	ldx #str_hello
	jsr puts

	;; ---- Talk device 2, register 0 (0010 1100 = $2C) ----
	lda #$2c
	sta adb_cmd
poll	lda adb_status
	and #$80		;busy?
	bne poll

	ldx #str_stat
	jsr puts
	lda adb_status
	jsr puthex8

	;; decode the interesting bits
	lda adb_status
	and #$20		;timeout
	beq notimeout
	ldx #str_to
	jsr puts
	bra shownum
notimeout ldx #str_resp
	jsr puts
shownum	lda adb_status
	and #$0f
	jsr puthex8
	ldx #str_bytes
	jsr puts

	;; ---- dump the data registers ----
	ldx #0
dumploop lda.w adb_data,x
	jsr puthex8
	lda #$20
	jsr putc
	inx
	cpx #8
	bne dumploop
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

str_hello text.0 "ADB host test",$0d,$0a
str_stat  text.0 "status="
str_to    text.0 " timeout, "
str_resp  text.0 " responded, "
str_bytes text.0 " bytes: "
str_crlf  text.0 $0d,$0a

	;; Reset vector, and IRQ/BRK in emulation mode
	org=$fffc
	data.w start
	data.w start
