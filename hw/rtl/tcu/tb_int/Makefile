## Makefile for VX_tcu_int integration testbench
## Tests the full integer TCU dispatch path:
##   tcu_exe_t → VX_tcu_int → (TCU_TC_M×TCU_TC_N) VX_tcu_fedp_int_scaled → tcu_res_t
##
## Usage:
##   make          - build and run (no waveform)
##   make wave     - run with VCD trace (wave_int.vcd)
##   make clean    - remove build artifacts

RTL_DIR  := $(abspath ../..)
LIBS_DIR := $(RTL_DIR)/libs
IFC_DIR  := $(RTL_DIR)/interfaces
TCU_DIR  := $(RTL_DIR)/tcu

VERILATOR := verilator

# --------------------------------------------------------------------------
# RTL source files (order matters for package resolution)
# --------------------------------------------------------------------------

## Packages (must come first)
PKG_SRCS := \
    $(RTL_DIR)/VX_gpu_pkg.sv     \
    $(TCU_DIR)/VX_tcu_pkg.sv

## Utility library primitives
LIB_SRCS := \
    $(LIBS_DIR)/VX_shift_register.sv  \
    $(LIBS_DIR)/VX_pipe_register.sv   \
    $(LIBS_DIR)/VX_dp_ram.sv          \
    $(LIBS_DIR)/VX_pending_size.sv    \
    $(LIBS_DIR)/VX_fifo_queue.sv

## Parameterized interfaces
IFC_SRCS := \
    $(IFC_DIR)/VX_execute_if.sv  \
    $(IFC_DIR)/VX_result_if.sv

## TCU core modules
TCU_SRCS := \
    $(TCU_DIR)/VX_tcu_fedp_int_scaled.sv  \
    $(TCU_DIR)/VX_tcu_int.sv

RTL_SRCS := $(PKG_SRCS) $(LIB_SRCS) $(IFC_SRCS) $(TCU_SRCS)

# --------------------------------------------------------------------------
# Testbench sources
# --------------------------------------------------------------------------
TB_SRC   := tb_tcu_int.sv
TB_MAIN  := main.cpp

BUILD_DIR := obj_dir
TARGET    := $(BUILD_DIR)/Vtb_tcu_int
VCD_FILE  := wave_int.vcd

# --------------------------------------------------------------------------
# Verilator flags
# --------------------------------------------------------------------------
VL_FLAGS  := --cc --exe --build
VL_FLAGS  += --timing
VL_FLAGS  += --trace                      # Always built with VCD support
VL_FLAGS  += --language 1800-2009
VL_FLAGS  += -Wall
VL_FLAGS  += -Wno-DECLFILENAME -Wno-REDEFMACRO
VL_FLAGS  += -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN
VL_FLAGS  += -Wno-TIMESCALEMOD -Wno-BLKSEQ -Wno-UNUSEDPARAM
VL_FLAGS  += -Wno-CASEINCOMPLETE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
VL_FLAGS  += --x-initial unique --x-assign unique
# Stability fix: prevent Verilator 5.028 coroutine crash
VL_FLAGS  += --output-split 1000000
VL_FLAGS  += --CFLAGS "-g -O0"

# Preprocessor defines
VL_FLAGS  += -DSIMULATION
VL_FLAGS  += -DXLEN_32
VL_FLAGS  += -DEXT_TCU_ENABLE            # Required: enables tcu_args_t in op_args_t
VL_FLAGS  += -DEXT_AG_TCU_ENABLE         # Required: enables exp_a/exp_b fields

# Include paths (must include RTL_DIR for VX_define.vh, VX_config.vh, VX_scope.vh)
VL_FLAGS  += -I$(RTL_DIR) -I$(LIBS_DIR) -I$(IFC_DIR) -I$(TCU_DIR)

# Top module and output
VL_FLAGS  += --top-module tb_tcu_int
VL_FLAGS  += --Mdir $(BUILD_DIR)
VL_FLAGS  += -o Vtb_tcu_int

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
.PHONY: all run wave clean

all: run

$(TARGET): $(TB_SRC) $(TB_MAIN) $(RTL_SRCS)
	$(VERILATOR) $(VL_FLAGS) $(RTL_SRCS) $(TB_SRC) $(TB_MAIN)

run: $(TARGET)
	@echo "==== Running VX_tcu_int Testbench ===="
	$(TARGET)

wave: $(TARGET)
	@echo "==== Running with VCD trace ===="
	$(TARGET) +trace=$(VCD_FILE)
	@echo "Waveform written to $(VCD_FILE)"

clean:
	rm -rf $(BUILD_DIR) $(VCD_FILE)
