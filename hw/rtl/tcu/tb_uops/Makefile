## Makefile for VX_tcu_uops register-address sequencer testbench
##
## Usage:
##   make          - build and run (NT=4, standard TCU: UOPS=16, LG_B_SB=0)
##   make NT=8     - build and run (NT=8: UOPS=32, LG_B_SB=1, + exp passthrough)
##   make both     - run NT=4 then NT=8
##   make wave     - run with VCD trace
##   make clean    - remove all build artifacts

RTL_DIR := $(abspath ../..)
TCU_DIR := $(RTL_DIR)/tcu

VERILATOR := verilator

# --------------------------------------------------------------------------
# NT selector (4 or 8)
# --------------------------------------------------------------------------
NT ?= 4

ifeq ($(NT),8)
  BUILD_DIR := obj_dir_nt8
  TARGET    := $(BUILD_DIR)/Vtb_tcu_uops
  VCD_FILE  := wave_uops_nt8.vcd
  NT_FLAGS  := -DNUM_THREADS=8 -DEXT_AG_TCU_ENABLE
else
  BUILD_DIR := obj_dir_nt4
  TARGET    := $(BUILD_DIR)/Vtb_tcu_uops
  VCD_FILE  := wave_uops_nt4.vcd
  NT_FLAGS  :=
endif

# --------------------------------------------------------------------------
# RTL source files
# --------------------------------------------------------------------------
PKG_SRCS := \
    $(RTL_DIR)/VX_gpu_pkg.sv  \
    $(TCU_DIR)/VX_tcu_pkg.sv

TB_SRC  := tb_tcu_uops.sv
TB_MAIN := main.cpp

RTL_SRCS := $(PKG_SRCS) $(TCU_DIR)/VX_tcu_uops.sv

# --------------------------------------------------------------------------
# Verilator flags
# --------------------------------------------------------------------------
VL_FLAGS  := --cc --exe --build
VL_FLAGS  += --timing
VL_FLAGS  += --trace
VL_FLAGS  += --language 1800-2009
VL_FLAGS  += -Wall
VL_FLAGS  += -Wno-DECLFILENAME -Wno-REDEFMACRO
VL_FLAGS  += -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN
VL_FLAGS  += -Wno-TIMESCALEMOD -Wno-BLKSEQ -Wno-UNUSEDPARAM
VL_FLAGS  += -Wno-CASEINCOMPLETE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
VL_FLAGS  += -Wno-PINMISSING -Wno-IMPLICIT
VL_FLAGS  += --x-initial unique --x-assign unique

# Preprocessor defines
VL_FLAGS  += -DSIMULATION
VL_FLAGS  += -DXLEN_32
VL_FLAGS  += -DEXT_TCU_ENABLE    # required: enables tcu_args_t in op_args_t
VL_FLAGS  += $(NT_FLAGS)

# Include paths
VL_FLAGS  += -I$(RTL_DIR)
VL_FLAGS  += -I$(TCU_DIR)

VL_FLAGS  += --top-module tb_tcu_uops
VL_FLAGS  += --Mdir $(BUILD_DIR)
VL_FLAGS  += -o Vtb_tcu_uops

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
.PHONY: all run wave clean both

all: run

$(TARGET): $(TB_SRC) $(TB_MAIN) $(RTL_SRCS)
	$(VERILATOR) $(VL_FLAGS) $(RTL_SRCS) $(TB_SRC) $(TB_MAIN)

run: $(TARGET)
	@echo "==== VX_tcu_uops TB (NT=$(NT)) ===="
	$(TARGET)

wave: $(TARGET)
	$(TARGET) +trace=$(VCD_FILE)
	@echo "Waveform: $(VCD_FILE)"

both:
	$(MAKE) NT=4 run
	$(MAKE) NT=8 run

clean:
	rm -rf obj_dir_nt4 obj_dir_nt8 wave_uops_nt4.vcd wave_uops_nt8.vcd
