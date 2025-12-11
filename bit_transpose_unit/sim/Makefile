# Makefile for BTU Simulation

# Tools
XVLOG = xvlog
XELAB = xelab
XSIM  = xsim

# Files
RTL_DIR = ../rtl
TB_DIR  = ../tb

RTL_SRCS = $(RTL_DIR)/btu_pkg.sv \
           $(RTL_DIR)/btu_sub_unit.sv \
           $(RTL_DIR)/btu_top.sv

TB_SRCS  = $(TB_DIR)/tb_btu.sv
TOP_MOD  = tb_btu
SNAPSHOT = tb_snapshot

.PHONY: all sim clean

all: sim

sim:
	@echo "Compiling..."
	$(XVLOG) -sv $(RTL_SRCS) $(TB_SRCS)
	@echo "Elaborating..."
	$(XELAB) -debug typical -top $(TOP_MOD) -snapshot $(SNAPSHOT)
	@echo "Simulating..."
	$(XSIM) $(SNAPSHOT) -R

gui:
	@echo "Compiling..."
	$(XVLOG) -sv $(RTL_SRCS) $(TB_SRCS)
	@echo "Elaborating..."
	$(XELAB) -debug typical -top $(TOP_MOD) -snapshot $(SNAPSHOT)
	@echo "Opening GUI..."
	$(XSIM) $(SNAPSHOT) -gui

clean:
	rm -rf xsim.dir .Xil
	rm -f *.log *.pb *.jou *.wdb *.vcd
