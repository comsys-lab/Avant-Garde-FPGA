# Makefile for Operand Transformer Simulation

# Tools
XVLOG = xvlog
XELAB = xelab
XSIM  = xsim

# Files
RTL_DIR = ../rtl
TB_DIR  = ../tb

# Simplified architecture with fixed-point multiplier
RTL_SRCS = $(RTL_DIR)/operand_tf_pkg.sv \
           $(RTL_DIR)/simple_multiplier.sv \
           $(RTL_DIR)/operand_tf_lane.sv \
           $(RTL_DIR)/operand_transformer_ctrl.sv \
           $(RTL_DIR)/operand_transformer_top.sv

TB_SRCS  = $(TB_DIR)/tb_operand_transformer.sv
TOP_MOD  = tb_operand_transformer
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
	rm -rf xsim.dir .Xil vivado_sim_proj *.jou *.log *.pb
	rm -f *.wdb *.vcd
