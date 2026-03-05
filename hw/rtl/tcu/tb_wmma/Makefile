## Makefile for tb_tcu_wmma — VX_tcu_unit full-WMMA K-accumulation testbench
##
## Tests the full TCU pipeline with all UOPS (K-accumulation):
##   dispatch_if → VX_dispatch_unit → VX_pe_switch
##     → VX_tcu_int (AG-TCU INT path)
##   → VX_gather_unit → commit_if
##   (NT=4 default: UOPS=16, TC_M=2, TC_N=2, TC_K=2)
##
## Usage:
##   make          - build and run
##   make wave     - run with VCD trace (wave_wmma.vcd)
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
# RTL source files
# --------------------------------------------------------------------------
PKG_SRCS := \
    $(RTL_DIR)/VX_gpu_pkg.sv      \
    $(TCU_DIR)/VX_tcu_pkg.sv

IFC_SRCS := \
    $(IFC_DIR)/VX_dispatch_if.sv  \
    $(IFC_DIR)/VX_commit_if.sv    \
    $(IFC_DIR)/VX_execute_if.sv   \
    $(IFC_DIR)/VX_result_if.sv

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

CORE_SRCS := \
    $(CORE_DIR)/VX_dispatch_unit.sv  \
    $(CORE_DIR)/VX_pe_switch.sv      \
    $(CORE_DIR)/VX_gather_unit.sv

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

TCU_SRCS := \
    $(TCU_DIR)/VX_tcu_fedp_int.sv         \
    $(TCU_DIR)/VX_tcu_fedp_int_scaled.sv  \
    $(TCU_DIR)/VX_tcu_scale_ctx.sv        \
    $(TCU_DIR)/VX_tcu_operand_transformer.sv  \
    $(TCU_DIR)/VX_tcu_fp.sv               \
    $(TCU_DIR)/VX_tcu_int.sv              \
    $(TCU_DIR)/VX_tcu_unit.sv

RTL_SRCS := $(PKG_SRCS) $(IFC_SRCS) $(LIB_SRCS) $(CORE_SRCS) \
            $(HF_SRCS) $(BHF_SRCS) $(TCU_SRCS)

# --------------------------------------------------------------------------
# Testbench sources
# --------------------------------------------------------------------------
TB_SRC  := tb_tcu_wmma.sv
TB_MAIN := main.cpp

BUILD_DIR := obj_dir
TARGET    := $(BUILD_DIR)/Vtb_tcu_wmma
VCD_FILE  := wave_wmma.vcd

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
VL_FLAGS  += -Wno-GENUNNAMED

VL_FLAGS  += --x-initial unique --x-assign unique
# --output-split 1000000: prevents Verilator from splitting the initial-block
# timing coroutine into sub-functions (DepSet__1.cpp, __2.cpp, ...).
# Verilator 5.028 has a sub-function dispatcher bug that fires whenever the
# coroutine is split into 3+ segments (segfault / heap corruption).  Keeping
# everything in a single __0.cpp avoids the dispatcher entirely.
# -O0 is required because a single large coroutine function at -O1/-O2 triggers
# a g++ register-pressure bug (32→64-bit zero-extension of rax used as pointer).
VL_FLAGS  += --output-split 1000000
VL_FLAGS  += --CFLAGS "-g -O0"

# Preprocessor defines
VL_FLAGS  += -DSIMULATION
VL_FLAGS  += -DXLEN_32
VL_FLAGS  += -DEXT_TCU_ENABLE
VL_FLAGS  += -DEXT_AG_TCU_ENABLE
VL_FLAGS  += -DTCU_BHF

# Include paths
VL_FLAGS  += -I$(RTL_DIR)
VL_FLAGS  += -I$(LIBS_DIR)
VL_FLAGS  += -I$(IFC_DIR)
VL_FLAGS  += -I$(TCU_DIR)
VL_FLAGS  += -I$(BHF_DIR)
VL_FLAGS  += -I$(HF_DIR)
VL_FLAGS  += -I$(HF_DIR)/RISCV
VL_FLAGS  += -I$(CORE_DIR)

VL_FLAGS  += --top-module tb_tcu_wmma
VL_FLAGS  += --Mdir $(BUILD_DIR)
VL_FLAGS  += -o Vtb_tcu_wmma

# Per-group test define (set by test-safe / test-stream / test-sat)
VL_FLAGS_EXTRA ?=
VL_FLAGS       += $(VL_FLAGS_EXTRA)

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
.PHONY: all run wave clean test-safe test-stream test-sat test-all \
       test-safe-nt8 test-stream-nt8 test-sat-nt8 test-all-nt8

all: run

$(TARGET): $(TB_SRC) $(TB_MAIN) $(RTL_SRCS)
	$(VERILATOR) $(VL_FLAGS) $(RTL_SRCS) $(TB_SRC) $(TB_MAIN)

run: $(TARGET)
	@echo "==== Running tb_tcu_wmma ===="
	$(TARGET)

wave: $(TARGET)
	@echo "==== Running with VCD trace ===="
	$(TARGET) +trace=$(VCD_FILE)
	@echo "Waveform written to $(VCD_FILE)"

clean:
	rm -rf $(BUILD_DIR) $(VCD_FILE)

# --------------------------------------------------------------------------
# Per-group test targets (each does a clean rebuild with its ifdef guard)
# Splits the initial block so Verilator generates ≤1 timing coroutine file,
# working around the Verilator 5.028 sub-coroutine dispatcher bug that fires
# when 7+ timing files are generated (≥199K total C++ lines).
# --------------------------------------------------------------------------
test-safe:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTESTS_SAFE"

test-stream:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTESTS_STREAM"

test-sat:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTESTS_SAT"

test-all: test-safe test-stream test-sat

# --------------------------------------------------------------------------
# NT=8 test targets (same ifdef groups, compiled with NUM_THREADS=8)
# --------------------------------------------------------------------------
test-safe-nt8:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTESTS_SAFE -DNUM_THREADS=8"

test-stream-nt8:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTESTS_STREAM -DNUM_THREADS=8"

test-sat-nt8:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTESTS_SAT -DNUM_THREADS=8"

test-all-nt8: test-safe-nt8 test-stream-nt8 test-sat-nt8
