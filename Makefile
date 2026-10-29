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

# interrupts taken while the bus waits: each run's checksum must be the
# reference's (no waits, no IRQ), with the bus contract kept
irqwait.mem: irqwait.s
	../65Tools/bin/as -o $@ irqwait.s > /dev/null

sim_irqwait: cpu_65c816.v tb_irqwait.v
	$(IVERILOG) -g2005 -Wall -o $@ cpu_65c816.v tb_irqwait.v

irqwait: sim_irqwait irqwait.mem
	@ref=$$($(VVP) -n sim_irqwait +nowait +noirq | grep -o 'sum=[0-9a-f]*'); \
	ok=1; for a in "+nowait" "+noirq" "" "+gap=300"; do \
	    out=$$($(VVP) -n sim_irqwait $$a | grep -E 'DONE|FAIL|TIMEOUT|CONTRACT'); \
	    echo "[$$a] $$out" | head -1; \
	    echo "$$out" | grep -q "DONE $$ref .*violations=0" || ok=0; \
	done; [ $$ok = 1 ] && echo "irqwait: ok" || { echo "irqwait: FAIL"; exit 1; }

clean:
	rm -f sim test.hex banked.mem sim_irqwait irqwait.mem

.PHONY: all run banked irqwait clean
