## Makefile for Level 8 tb_decode testbench
## DUT: VX_decode + VX_issue + VX_execute + VX_commit
## Tests: VX_decode field verification + end-to-end LDSCALE/WMMA
##
## Usage:
##   make       - build and run (7 TCs)
##   make wave  - run with VCD trace
##   make clean - remove build artifacts

RTL_DIR    := $(abspath ../..)
LIBS_DIR   := $(RTL_DIR)/libs
IFC_DIR    := $(RTL_DIR)/interfaces
MEM_DIR    := $(RTL_DIR)/mem
TCU_DIR    := $(RTL_DIR)/tcu
BHF_DIR    := $(TCU_DIR)/bhf
CORE_DIR   := $(RTL_DIR)/core
FPU_DIR    := $(RTL_DIR)/fpu
HF_DIR     := $(abspath ../../../../third_party/hardfloat/source)

VERILATOR := verilator

# --------------------------------------------------------------------------
# RTL source files
# --------------------------------------------------------------------------

## 1. Packages
PKG_SRCS := \
    $(RTL_DIR)/VX_gpu_pkg.sv      \
    $(FPU_DIR)/VX_fpu_pkg.sv      \
    $(TCU_DIR)/VX_tcu_pkg.sv

## 2. Interfaces (L7 set + L8 additions: VX_fetch_if, VX_decode_sched_if)
IFC_SRCS := \
    $(IFC_DIR)/VX_fetch_if.sv         \
    $(IFC_DIR)/VX_decode_sched_if.sv  \
    $(IFC_DIR)/VX_decode_if.sv        \
    $(IFC_DIR)/VX_ibuffer_if.sv       \
    $(IFC_DIR)/VX_scoreboard_if.sv    \
    $(IFC_DIR)/VX_operands_if.sv      \
    $(IFC_DIR)/VX_issue_sched_if.sv   \
    $(IFC_DIR)/VX_dispatch_if.sv      \
    $(IFC_DIR)/VX_commit_if.sv        \
    $(IFC_DIR)/VX_execute_if.sv       \
    $(IFC_DIR)/VX_result_if.sv        \
    $(IFC_DIR)/VX_branch_ctl_if.sv    \
    $(IFC_DIR)/VX_warp_ctl_if.sv      \
    $(IFC_DIR)/VX_commit_csr_if.sv    \
    $(IFC_DIR)/VX_sched_csr_if.sv     \
    $(IFC_DIR)/VX_writeback_if.sv     \
    $(IFC_DIR)/VX_commit_sched_if.sv  \
    $(FPU_DIR)/VX_fpu_csr_if.sv       \
    $(MEM_DIR)/VX_lsu_mem_if.sv

## 3. Library primitives
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
    $(LIBS_DIR)/VX_stream_switch.sv    \
    $(LIBS_DIR)/VX_reduce_tree.sv      \
    $(LIBS_DIR)/VX_priority_encoder.sv \
    $(LIBS_DIR)/VX_elastic_adapter.sv  \
    $(LIBS_DIR)/VX_allocator.sv        \
    $(LIBS_DIR)/VX_index_buffer.sv     \
    $(LIBS_DIR)/VX_find_first.sv       \
    $(LIBS_DIR)/VX_mem_coalescer.sv    \
    $(LIBS_DIR)/VX_mem_scheduler.sv    \
    $(LIBS_DIR)/VX_serial_mul.sv       \
    $(LIBS_DIR)/VX_serial_div.sv       \
    $(LIBS_DIR)/VX_multiplier.sv

## 4. Core dispatch/PE-switch/gather
DISPATCH_SRCS := \
    $(CORE_DIR)/VX_dispatch_unit.sv  \
    $(CORE_DIR)/VX_pe_switch.sv      \
    $(CORE_DIR)/VX_gather_unit.sv

## 5. HardFloat library
HF_SRCS := \
    $(HF_DIR)/HardFloat_primitives.v    \
    $(HF_DIR)/HardFloat_rawFN.v         \
    $(HF_DIR)/fNToRecFN.v               \
    $(HF_DIR)/recFNToFN.v               \
    $(HF_DIR)/addRecFN.v                \
    $(HF_DIR)/mulRecFN.v

## 6. BHF floating-point sub-modules
BHF_SRCS := \
    $(BHF_DIR)/bsg_counting_leading_zeros.sv  \
    $(BHF_DIR)/VX_tcu_bhf_bf16mul.sv          \
    $(BHF_DIR)/VX_tcu_bhf_fmul.sv             \
    $(BHF_DIR)/VX_tcu_bhf_fadd.sv             \
    $(TCU_DIR)/VX_tcu_fedp_bhf.sv

## 7. TCU execution modules
TCU_SRCS := \
    $(TCU_DIR)/VX_tcu_fedp_int.sv         \
    $(TCU_DIR)/VX_tcu_fedp_int_scaled.sv  \
    $(TCU_DIR)/VX_tcu_scale_ctx.sv        \
    $(TCU_DIR)/VX_tcu_operand_transformer.sv  \
    $(TCU_DIR)/VX_tcu_fp.sv               \
    $(TCU_DIR)/VX_tcu_int.sv              \
    $(TCU_DIR)/VX_tcu_unit.sv             \
    $(TCU_DIR)/VX_tcu_uops.sv

## 8. FPU unit stub
FPU_SRCS := \
    VX_fpu_unit_stub.sv

## 9. Core ALU modules
ALU_SRCS := \
    $(CORE_DIR)/VX_alu_int.sv      \
    $(CORE_DIR)/VX_alu_muldiv.sv   \
    $(CORE_DIR)/VX_alu_unit.sv

## 10. Core SFU modules
SFU_SRCS := \
    $(CORE_DIR)/VX_wctl_unit.sv    \
    $(CORE_DIR)/VX_csr_data.sv     \
    $(CORE_DIR)/VX_csr_unit.sv     \
    $(CORE_DIR)/VX_sfu_unit.sv

## 11. Core LSU modules (never dispatched)
LSU_SRCS := \
    $(CORE_DIR)/VX_lsu_slice.sv    \
    $(CORE_DIR)/VX_lsu_unit.sv

## 12. Execute + Commit stage
EX_COMMIT_SRCS := \
    $(CORE_DIR)/VX_execute.sv  \
    $(CORE_DIR)/VX_commit.sv

## 13. Issue stage modules
ISSUE_SRCS := \
    $(CORE_DIR)/VX_uop_sequencer.sv \
    $(CORE_DIR)/VX_ibuffer.sv       \
    $(CORE_DIR)/VX_scoreboard.sv    \
    $(CORE_DIR)/VX_operands.sv      \
    $(CORE_DIR)/VX_dispatch.sv      \
    $(CORE_DIR)/VX_issue_slice.sv   \
    $(CORE_DIR)/VX_issue.sv

## 14. Decode stage (new for Level 8)
DECODE_SRCS := \
    $(CORE_DIR)/VX_decode.sv

RTL_SRCS := $(PKG_SRCS) $(IFC_SRCS) $(LIB_SRCS) $(DISPATCH_SRCS) \
            $(HF_SRCS) $(BHF_SRCS) $(TCU_SRCS)                   \
            $(FPU_SRCS) $(ALU_SRCS) $(SFU_SRCS) $(LSU_SRCS)      \
            $(EX_COMMIT_SRCS) $(ISSUE_SRCS) $(DECODE_SRCS)

# --------------------------------------------------------------------------
# Testbench sources
# --------------------------------------------------------------------------
TB_SRC  := tb_decode.sv
TB_MAIN := main.cpp

BUILD_DIR := obj_dir
TARGET    := $(BUILD_DIR)/Vtb_decode
VCD_FILE  := wave_decode.vcd

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
VL_FLAGS  += -Wno-IMPORTSTAR -Wno-VARHIDDEN

# Stability fix: prevent Verilator 5.028 coroutine crash
VL_FLAGS  += --x-initial unique --x-assign unique
VL_FLAGS  += --output-split 1000000
VL_FLAGS  += --output-split-cfuncs 1000000
VL_FLAGS  += --CFLAGS "-g -O0"
# Speed fix: use 1ns precision so timeInc(1) = 1ns (1000x faster than 1ps)
VL_FLAGS  += --timescale-override 1ns/1ns

# Preprocessor defines
VL_FLAGS  += -DSIMULATION
VL_FLAGS  += -DXLEN_32
VL_FLAGS  += -DEXT_TCU_ENABLE
VL_FLAGS  += -DEXT_AG_TCU_ENABLE
VL_FLAGS  += -DTCU_BHF
VL_FLAGS  += -DL1_ENABLE    # removes ibuf_pop from VX_fetch_if

# Include paths
VL_FLAGS  += -I$(RTL_DIR)
VL_FLAGS  += -I$(LIBS_DIR)
VL_FLAGS  += -I$(IFC_DIR)
VL_FLAGS  += -I$(MEM_DIR)
VL_FLAGS  += -I$(TCU_DIR)
VL_FLAGS  += -I$(BHF_DIR)
VL_FLAGS  += -I$(FPU_DIR)
VL_FLAGS  += -I$(HF_DIR)
VL_FLAGS  += -I$(HF_DIR)/RISCV
VL_FLAGS  += -I$(CORE_DIR)

# Top module and output directory
VL_FLAGS  += --top-module tb_decode
VL_FLAGS  += --Mdir $(BUILD_DIR)
VL_FLAGS  += -o Vtb_decode

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
.PHONY: all run wave clean

all: run

$(TARGET): $(TB_SRC) $(TB_MAIN) $(RTL_SRCS)
	$(VERILATOR) $(VL_FLAGS) $(RTL_SRCS) $(TB_SRC) $(TB_MAIN)

run: $(TARGET)
	@echo "==== Running Level 8: VX_decode + VX_issue + VX_execute + VX_commit ===="
	$(TARGET)

wave: $(TARGET)
	@echo "==== Running with VCD trace ===="
	$(TARGET) +trace=$(VCD_FILE)
	@echo "Waveform written to $(VCD_FILE)"

clean:
	rm -rf $(BUILD_DIR) $(VCD_FILE)
