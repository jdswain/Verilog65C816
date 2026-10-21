IVERILOG ?= iverilog
VVP      ?= vvp

all: run

test.hex: test_gen.py
	python3 test_gen.py

sim: cpu_65c816.v tb_cpu.v
	$(IVERILOG) -g2005 -Wall -o sim cpu_65c816.v tb_cpu.v

run: sim test.hex
	$(VVP) sim

# the banked direct page and stack (docs/BankedDP.md)
banked.mem: banked.s
	../65Tools/bin/as -D BENCH=1 -o $@ banked.s > /dev/null

banked: sim banked.mem
	$(VVP) sim +hex=banked.mem

clean:
	rm -f sim test.hex banked.mem

.PHONY: all run banked clean
