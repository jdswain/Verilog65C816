IVERILOG ?= iverilog
VVP      ?= vvp

all: run

test.hex: test_gen.py
	python3 test_gen.py

sim: cpu_65c816.v tb_cpu.v
	$(IVERILOG) -g2005 -Wall -o sim cpu_65c816.v tb_cpu.v

run: sim test.hex
	$(VVP) sim

clean:
	rm -f sim test.hex

.PHONY: all run clean
