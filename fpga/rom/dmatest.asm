********************************************************************************
* dmatest - the DMA engine's memory side, on the bare board                    *
*                                                                              *
* Without the carrier, pin 80 (DRQ1) is pulled high, so channel 1 always sees  *
* a request, and ext_d is pulled up, so a read from the bus gives $FF. This    *
* runs channel 1 both ways and checks what lands in memory:                    *
*   1. 512 bytes of $5A, read by the CPU (so they are in its cache), then a    *
*      device-to-memory transfer over them: the CPU must now read $FF (the     *
*      cache dropped the lines the engine wrote). ADDR and COUNT at the end.   *
*   2. A memory-to-device transfer of the same 512 bytes, with TC: DONE.       *
*   3. Two bytes to $1301: $1300 and $1303 untouched (a partial word).         *
* Prints "dma: ok", or "dma: fail" and the number of the check that failed.   *
* The simulation runs it with +drq1 (tb_soc).                                  *
********************************************************************************

	include "mon-fixes/65816.asm"

	section "text"
	org=$e000

	include "scc.asm"

	dma1_addr  = $0410	;channel 1: ADDR low, middle, bank
	dma1_count = $0414	;COUNT low, middle, high
	dma1_ctrl  = $0418	;0 EN, 1 DIR (1 = memory to device), 2 TC, 3 IE
	dma1_stat  = $0419	;7 BUSY, 6 DRQ, 0 DONE (write 1 to clear)
	buf        = $1000

start	native
	short_a
	long_i
	jsr scc_init
	ldx #str_hello
	jsr puts

	;; ---- 1. device to memory over cached bytes ----
	ldx #0
fillb	lda #$5a
	sta buf,x
	inx
	cpx #$200
	bne fillb
	ldx #0
	lda #0
cache	ora buf,x		;read them all, so the cache holds them
	inx
	cpx #$200
	bne cache
	cmp #$5a
	beq c1ok
	lda #1
	jmp fail
c1ok	lda #<buf
	ldx #$0200
	jsr setup
	lda #$01		;device to memory, EN
	sta dma1_ctrl
	jsr wait
	ldx #0
chk1	lda buf,x
	cmp #$ff
	beq chk1n
	lda #2
	jmp fail
chk1n	inx
	cpx #$200
	bne chk1
	lda buf+$200		;the byte after: untouched
	cmp #$ee
	beq chk1a
	lda #3
	jmp fail
chk1a	lda dma1_addr+1		;ADDR = $001200
	cmp #$12
	bne bad4
	lda dma1_addr
	bne bad4
	lda dma1_count
	ora dma1_count+1
	ora dma1_count+2
	bne bad4
	lda dma1_stat
	and #$81
	cmp #$01		;DONE, not BUSY
	beq chk1s
bad4	lda #4
	jmp fail
chk1s	lda #$01
	sta dma1_stat
	lda dma1_stat
	and #$01
	beq m2d
	lda #5
	jmp fail

	;; ---- 2. memory to device, with TC ----
m2d	lda #<buf
	ldx #$0200
	jsr setup
	lda #$07		;TC, memory to device, EN
	sta dma1_ctrl
	jsr wait
	lda dma1_count+1
	ora dma1_count
	beq part
	lda #6
	jmp fail

	;; ---- 3. a partial word ----
part	lda #$33
	sta buf+$300
	sta buf+$301
	sta buf+$302
	sta buf+$303
	lda buf+$300		;cache the word
	lda #1
	sta dma1_stat
	lda #$01
	sta dma1_addr
	lda #$13
	sta dma1_addr+1
	stz dma1_addr+2
	lda #2
	sta dma1_count
	stz dma1_count+1
	stz dma1_count+2
	lda #$01
	sta dma1_ctrl
	jsr wait
	lda buf+$300
	cmp #$33
	bne bad7
	lda buf+$301
	cmp #$ff
	bne bad7
	lda buf+$302
	cmp #$ff
	bne bad7
	lda buf+$303
	cmp #$33
	beq allok
bad7	lda #7
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

	;; channel 1: ADDR = $00:10xx (A the low byte), COUNT = X
setup	stz dma1_ctrl
	sta dma1_addr
	lda #>buf
	sta dma1_addr+1
	stz dma1_addr+2
	txa
	sta dma1_count
	rep #$20
	txa
	sep #$20
	xba			;the high byte of X
	sta dma1_count+1
	stz dma1_count+2
	lda #1
	sta dma1_stat		;clear DONE
	lda #$ee
	sta buf+$200		;the byte after the buffer
	rts

	;; until DONE, or give up (check 8): DRQ1 low, or the engine stuck
wait	ldy #0
wt	lda dma1_stat
	and #$01
	bne wtok
	dey
	bne wt
	pla			;drop the return address
	pla
	lda #8
	jmp fail
wtok	rts

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

str_hello text.0 "dma test",$0d,$0a
str_ok    text.0 "dma: ok",$0d,$0a
str_fail  text.0 "dma: fail "
str_crlf  text.0 $0d,$0a

	;; Reset vector, and IRQ/BRK in emulation mode
	org=$fffc
	data.w start
	data.w start
