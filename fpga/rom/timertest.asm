********************************************************************************
* timertest - the tick timer ($0450) and interrupt status ($0440)              *
*                                                                              *
*   1. ISTAT reads 0 and IMASK $FF after reset.                                *
*   2. A 1000-clock period, polled: PENDING and ISTAT bit 0 set at the tick,   *
*      both clear after writing 1 to STATUS.                                   *
*   3. On IRQ: the handler counts ticks and clears PENDING; after 10 of them,  *
*      TICKS (latched by reading its low byte) is 11 to 15.                    *
*   4. IMASK bit 0 clear: the tick is pending (ISTAT shows it) but no IRQ;     *
*      setting the bit again takes the IRQ at once.                            *
*   5. DMA channel 1 started with COUNT = 0 and IE: DONE at once, ISTAT bit 2  *
*      only, gone after DONE is cleared.                                       *
* Prints "timer: ok", or "timer: fail" and the number of the check that       *
* failed.                                                                      *
********************************************************************************

	include "mon-fixes/65816.asm"

	section "text"
	org=$e000

	include "scc.asm"

	istat      = $0440	;0 timer, 1 DMA 0, 2 DMA 1, 3 cards, 4 SCC
	imask      = $0441	;1 = the source reaches the IRQ
	tmr_reload = $0450	;the period in system clocks, low first
	tmr_ctrl   = $0452	;bit 0 EN
	tmr_stat   = $0453	;bit 0 PENDING (write 1 to clear)
	tmr_ticks  = $0458	;reading the low byte latches the rest
	dma1_ctrl  = $0418
	dma1_stat  = $0419
	count      = $2000	;ticks the IRQ handler has seen

start	native
	short_a
	long_i
	jsr scc_init
	ldx #str_hello
	jsr puts

	;; ---- 1. after reset ----
	lda istat
	beq c1ok
	lda #1
	jmp fail
c1ok	lda imask
	cmp #$ff
	beq c2
	lda #1
	jmp fail

	;; ---- 2. polled ----
c2	lda #<1000
	sta tmr_reload
	lda #>1000
	sta tmr_reload+1
	lda #1
	sta tmr_ctrl		;EN
	jsr waitset
	lda istat
	cmp #$01
	beq c2a
	lda #2
	jmp fail
c2a	lda #1
	sta tmr_stat
	lda tmr_stat
	ora istat
	beq c3
	lda #2
	jmp fail

	;; ---- 3. on IRQ ----
c3	stz count
	cli
	ldy #0
c3w	lda count
	cmp #10
	bcs c3d
	dey
	bne c3w
	sei
	lda #3
	jmp fail
c3d	sei
	lda tmr_ticks		;latches the rest
	cmp #11
	bcc bad3
	cmp #16
	bcs bad3
	lda tmr_ticks+1
	ora tmr_ticks+2
	ora tmr_ticks+3
	beq c4
bad3	lda #3
	jmp fail

	;; ---- 4. masked ----
c4	lda #$fe
	sta imask
	lda #1
	sta tmr_stat
	stz count
	cli
	jsr waitpend
	jsr waitset		;a whole period, then the tick left pending
	lda count
	bne bad4
	lda istat
	cmp #$01
	bne bad4
	lda #$ff
	sta imask		;the IRQ now
	nop
	nop
	nop
	sei
	lda count
	cmp #1
	beq c4d
bad4	lda #4
	jmp fail
c4d	stz tmr_ctrl
	lda #1
	sta tmr_stat

	;; ---- 5. DMA channel 1 done ----
	sta dma1_stat		;clear DONE
	lda #$09		;IE, EN; COUNT is 0 from reset
	sta dma1_ctrl
	lda istat
	cmp #$04
	bne bad5
	lda #1
	sta dma1_stat
	lda istat
	beq allok
bad5	lda #5
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

	;; until PENDING, polled, and clear it, so the next call waits a whole
	;; period
waitpend jsr waitset
	lda #1
	sta tmr_stat
	rts

	;; until PENDING, polled, leaving it set; give up after 65536 tries
	;; (check 6)
waitset	ldy #0
ws	lda tmr_stat
	and #1
	bne wsok
	dey
	bne ws
	pla			;drop the return address
	pla
	lda #6
	jmp fail
wsok	rts

	;; The IRQ handler, native mode: count a tick and clear it
irq	pha
	lda tmr_stat
	and #1
	beq irq_x
	sta tmr_stat
	inc count
irq_x	pla
	rti

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

str_hello text.0 "timer test",$0d,$0a
str_ok    text.0 "timer: ok",$0d,$0a
str_fail  text.0 "timer: fail "
str_crlf  text.0 $0d,$0a

	;; Native IRQ; reset, and IRQ/BRK in emulation mode
	org=$ffee
	data.w irq
	org=$fffc
	data.w start
	data.w start
