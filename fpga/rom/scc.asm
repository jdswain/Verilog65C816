********************************************************************************
* scc.asm - the serial port for the test ROMs                                  *
*                                                                              *
* Channel A of the Z85C30 SCC at $0820, emulated in the FPGA (rtl/scc_85c30.v) *
* until the carrier board's Z85C80 replaces it. Include it after the org;      *
* call scc_init before the first character, with an 8 bit accumulator. It      *
* does not touch the index registers, so either width will do.                 *
********************************************************************************

	scc_actl   = $0822		;channel A control: RR0 with the pointer at 0
	scc_adata  = $0823		;channel A data

	ser_status = scc_actl
	ser_data   = scc_adata
	ser_rxrdy  = $01		;RR0: receive character available
	ser_txrdy  = $04		;RR0: transmit buffer empty

	;; Writes register/value pairs to channel A's control port. The time
	;; constant is for 115200 baud from a 7.3728 MHz clock on PCLK and
	;; RTxC; the emulated SCC runs at 115200 whatever is written.
scc_init lda ser_status		;puts the pointer back to 0
	lda #9
	sta scc_actl
	lda #$c0		;WR9: hardware reset
	sta scc_actl
	lda #4
	sta scc_actl
	lda #$44		;WR4: x16 clock, 1 stop bit, no parity
	sta scc_actl
	lda #3
	sta scc_actl
	lda #$c0		;WR3: receive 8 bits
	sta scc_actl
	lda #5
	sta scc_actl
	lda #$60		;WR5: transmit 8 bits
	sta scc_actl
	lda #11
	sta scc_actl
	lda #$50		;WR11: clocks from the BRG
	sta scc_actl
	lda #12
	sta scc_actl
	lda #0			;WR12: time constant, low
	sta scc_actl
	lda #13
	sta scc_actl
	lda #0			;WR13: time constant, high
	sta scc_actl
	lda #14
	sta scc_actl
	lda #$01		;WR14: BRG on, clocked from RTxC
	sta scc_actl
	lda #3
	sta scc_actl
	lda #$c1		;WR3: receiver on
	sta scc_actl
	lda #5
	sta scc_actl
	lda #$ea		;WR5: transmitter on, DTR and RTS asserted
	sta scc_actl
	rts
