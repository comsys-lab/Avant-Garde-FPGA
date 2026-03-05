## Makefile for VX_tcu_unit system-level testbench
## Tests the full TCU pipeline:
##   dispatch_if → VX_dispatch_unit → VX_pe_switch
##     → VX_tcu_int (AG-TCU INT path)
##     → VX_tcu_fp  (FP path, compiled but not exercised in INT tests)
##   → VX_gather_unit → commit_if
##
## Usage:
##   make          - build and run
##   make wave     - run with VCD trace (wave_unit.vcd)
##   make clean    - remove build artifacts

RTL_DIR    := $(abspath ../..)
LIBS_DIR   := $(RTL_DIR)/libs
IFC_DIR    := $(RTL_DIR)/interfaces
TCU_DIR    := $(RTL_DIR)/tcu
BHF_DIR    := $(TCU_DIR)/bhf
CORE_DIR   := $(RTL_DIR)/core
HF_DIR     := $(abspath ../../../..)/third_party/hardfloat/source

VERILATOR := verilator

# --------------------------------------------------------------------------
# RTL source files (dependency order matters for package resolution)
# --------------------------------------------------------------------------

## 1. Packages (must come first so types are visible to all modules)
PKG_SRCS := \
    $(RTL_DIR)/VX_gpu_pkg.sv      \
    $(TCU_DIR)/VX_tcu_pkg.sv

## 2. Parameterized interfaces
IFC_SRCS := \
    $(IFC_DIR)/VX_dispatch_if.sv  \
    $(IFC_DIR)/VX_commit_if.sv    \
    $(IFC_DIR)/VX_execute_if.sv   \
    $(IFC_DIR)/VX_result_if.sv

## 3. Library primitives (leaves first to avoid forward-reference warnings)
LIB_SRCS := \
    $(LIBS_DIR)/VX_pipe_register.sv    \
    $(LIBS_DIR)/VX_shift_register.sv   \
    $(LIBS_DIR)/VX_dp_ram.sv           \
    $(LIBS_DIR)/VX_pending_size.sv     \
    $(LIBS_DIR)/VX_fifo_queue.sv       \
    $(LIBS_DIR)/VX_pipe_buffer.sv      \
    $(LIBS_DIR)/VX_stream_buffer.sv    \
    $(LIBS_DIR)/VX_elastic_buffer.sv   \
    $(LIBS_DIR)/VX_generic_arbiter.sv  \
    $(LIBS_DIR)/VX_nz_iterator.sv      \
    $(LIBS_DIR)/VX_stream_arb.sv       \
    $(LIBS_DIR)/VX_stream_switch.sv

## 4. Core dispatch / PE-switch / gather infrastructure
CORE_SRCS := \
    $(CORE_DIR)/VX_dispatch_unit.sv  \
    $(CORE_DIR)/VX_pe_switch.sv      \
    $(CORE_DIR)/VX_gather_unit.sv

## 5. BHF floating-point sub-modules (required to compile VX_tcu_fp)
##    We define TCU_BHF so VX_tcu_fp instantiates the BHF FEDP.
##    Depends on Berkeley HardFloat library in third_party/hardfloat/source/.
HF_SRCS := \
    $(HF_DIR)/HardFloat_primitives.v    \
    $(HF_DIR)/HardFloat_rawFN.v         \
    $(HF_DIR)/fNToRecFN.v               \
    $(HF_DIR)/recFNToFN.v               \
    $(HF_DIR)/addRecFN.v                \
    $(HF_DIR)/mulRecFN.v

BHF_SRCS := \
    $(BHF_DIR)/bsg_counting_leading_zeros.sv  \
    $(BHF_DIR)/VX_tcu_bhf_bf16mul.sv          \
    $(BHF_DIR)/VX_tcu_bhf_fmul.sv             \
    $(BHF_DIR)/VX_tcu_bhf_fadd.sv             \
    $(TCU_DIR)/VX_tcu_fedp_bhf.sv

## 6. TCU execution modules
TCU_SRCS := \
    $(TCU_DIR)/VX_tcu_fedp_int.sv         \
    $(TCU_DIR)/VX_tcu_fedp_int_scaled.sv  \
    $(TCU_DIR)/VX_tcu_scale_ctx.sv        \
    $(TCU_DIR)/VX_tcu_operand_transformer.sv  \
    $(TCU_DIR)/VX_tcu_fp.sv               \
    $(TCU_DIR)/VX_tcu_int.sv              \
    $(TCU_DIR)/VX_tcu_unit.sv

RTL_SRCS := $(PKG_SRCS) $(IFC_SRCS) $(LIB_SRCS) $(CORE_SRCS) $(HF_SRCS) $(BHF_SRCS) $(TCU_SRCS)

# --------------------------------------------------------------------------
# Testbench sources
# --------------------------------------------------------------------------
TB_SRC  := tb_tcu_unit.sv
TB_MAIN := main.cpp

BUILD_DIR := obj_dir
TARGET    := $(BUILD_DIR)/Vtb_tcu_unit
VCD_FILE  := wave_unit.vcd

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
VL_FLAGS  += -Wno-GENUNNAMED                  # old-style Verilog in HardFloat lib
VL_FLAGS  += --x-initial unique --x-assign unique

# --output-split 1000000: prevents timing coroutine sub-function splits.
# Verilator 5.028 sub-dispatcher crashes with 3+ segments (segfault/heap).
# -O0: avoids g++ register-pressure bug in large unsplit coroutine functions.
VL_FLAGS  += --output-split 1000000
VL_FLAGS  += --CFLAGS "-g -O0"

# Preprocessor defines
VL_FLAGS  += -DSIMULATION
VL_FLAGS  += -DXLEN_32
VL_FLAGS  += -DEXT_TCU_ENABLE             # enables tcu_args_t in op_args_t union
VL_FLAGS  += -DEXT_AG_TCU_ENABLE          # enables exp_a/exp_b in tcu_args_t
VL_FLAGS  += -DTCU_BHF                    # selects BHF FEDP for VX_tcu_fp

# Include paths
VL_FLAGS  += -I$(RTL_DIR)                 # VX_define.vh, VX_config.vh, VX_scope.vh
VL_FLAGS  += -I$(LIBS_DIR)
VL_FLAGS  += -I$(IFC_DIR)
VL_FLAGS  += -I$(TCU_DIR)
VL_FLAGS  += -I$(BHF_DIR)                # HardFloat_consts.vi, HardFloat_localFuncs.vi
VL_FLAGS  += -I$(HF_DIR)                 # HardFloat_consts.vi (hardfloat repo copy)
VL_FLAGS  += -I$(HF_DIR)/RISCV           # HardFloat_specialize.vi
VL_FLAGS  += -I$(CORE_DIR)

# Extra flags injected by per-NT test targets (e.g. -DNUM_THREADS=8)
VL_FLAGS_EXTRA ?=
VL_FLAGS       += $(VL_FLAGS_EXTRA)

# Top module and output directory
VL_FLAGS  += --top-module tb_tcu_unit
VL_FLAGS  += --Mdir $(BUILD_DIR)
VL_FLAGS  += -o Vtb_tcu_unit

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
.PHONY: all run wave clean test-nt4 test-nt8 test-all

all: run

$(TARGET): $(TB_SRC) $(TB_MAIN) $(RTL_SRCS)
	$(VERILATOR) $(VL_FLAGS) $(RTL_SRCS) $(TB_SRC) $(TB_MAIN)

run: $(TARGET)
	@echo "==== Running VX_tcu_unit Testbench ===="
	$(TARGET)

wave: $(TARGET)
	@echo "==== Running with VCD trace ===="
	$(TARGET) +trace=$(VCD_FILE)
	@echo "Waveform written to $(VCD_FILE)"

clean:
	rm -rf $(BUILD_DIR) $(VCD_FILE)

# --------------------------------------------------------------------------
# Per-NT test targets
# --------------------------------------------------------------------------
test-nt4:
	$(MAKE) clean
	$(MAKE) run

test-nt8:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DNUM_THREADS=8 -DTESTS_NT8"

test-all: test-nt4 test-nt8
