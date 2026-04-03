## Makefile for tb_tcu_wmma — VX_tcu_unit full-WMMA K-accumulation testbench
##
## Tests the full TCU pipeline with all UOPS (K-accumulation):
##   dispatch_if → VX_dispatch_unit → VX_pe_switch
##     → VX_tcu_operand_transformer → VX_tcu_fp / VX_tcu_int
##   → VX_gather_unit → commit_if
##
## Usage:
##   make        - build and run (NT=4 default)
##   make nt8    - build and run with NT=8
##   make wave   - run with VCD trace
##   make clean  - remove build artifacts

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
    $(TCU_DIR)/VX_tcu_micro_ctx.sv        \
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
# Prevent Verilator 5.028 coroutine-split dispatcher bug (SIGSEGV on 3+ splits)
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

VL_FLAGS_EXTRA ?=
VL_FLAGS       += $(VL_FLAGS_EXTRA)

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
.PHONY: all run wave clean nt8
.PHONY: test-all test-safe test-int8 test-mxint8 test-mx9 test-flat test-fp8 test-mxfp8 test-3level

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

# NT=8: all formats, NT=8
nt8:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DNUM_THREADS=8"

# --------------------------------------------------------------------------
# Per-format test targets
# Each target rebuilds with the appropriate format define.
# test-all / test-safe run all formats in one binary (no format define).
# --------------------------------------------------------------------------

test-all test-safe:
	$(MAKE) clean
	$(MAKE) run

test-int8:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTCU_TEST_INT8"

test-mxint8:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTCU_TEST_MXINT8"

test-mx9:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTCU_TEST_MX9"

test-flat:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTCU_TEST_FLAT"

test-fp8:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTCU_TEST_FP8"

test-mxfp8:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTCU_TEST_MXFP8"

test-3level:
	$(MAKE) clean
	$(MAKE) run VL_FLAGS_EXTRA="-DTCU_TEST_3LEVEL"
