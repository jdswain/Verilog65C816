****************************************
* 65816 defines and macros             *
*                                      *
****************************************
	
	cpu = "816"
	longa = off
	longi = off
	
	;; Flag values for use with the
	;; REP and SEP instructions
	
	N_FLAG = 1<<7
	V_FLAG = 1<<6
	M_FLAG = 1<<5
	X_FLAG = 1<<4
	B_FLAG = 1<<4
	D_FLAG = 1<<3
	I_FLAG = 1<<2
	Z_FLAG = 1<<1
	C_FLAG = 1<<0

	;; Register definitions

	section dp
	
	org = 0			;Actually Direct Page

process_info:	data.w 0	;Process info (in bank 0)
sframe_ptr:	data.w 0	;Stack frame address

r0:	data.w 0,0
r1:	data.w 0,0
r2:	data.w 0,0
r3:	data.w 0,0
r4:	data.w 0,0
r5:	data.w 0,0
r6:	data.w 0,0
r7:	data.w 0,0

	;; Register alias

	;; Floating point registers
	f0 = r0
	f1 = r1
	f2 = r2
	f3 = r3
	f4 = r4
	f5 = r5
	f6 = r6
	f7 = r7

	;; Double registers
	d0 = r0
	d1 = r2
	d2 = r4
	d3 = r6
	
emulate 	macro {
		sec
		xce
		}
	
native		macro {
		clc
		xce
		}

long_a		macro {
		rep #M_FLAG
		longa = on
		}

long_i		macro {
		rep #X_FLAG
		longi = on
		}

long_ai		macro {
		rep #M_FLAG | X_FLAG
		longa = on
		longi = on
		}

short_a		macro {
		sep #M_FLAG
		longa = off
		}

short_i		macro {
		sep #X_FLAG
		longi = off
		}

short_ai 	macro {
		sep #M_FLAG | X_FLAG
		longa = off
		longi = off
		}

sframe		macro frame_size {
		lda sframe_ptr
		pha
		tsa
		sec
		sbc #frame_size
		tas
		sta sframe_ptr
		}

eframe 		macro frame_size {
		tsa
		clc
		adc frame_size
		tas
		pla
		sta sframe_ptr
		}
