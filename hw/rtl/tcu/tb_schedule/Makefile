## Makefile for Level 9 tb_schedule testbench
## DUT: VX_schedule (warp scheduler, PC management, stall/release, branch)
##
## Usage:
##   make       - build and run (6 TCs)
##   make wave  - run with VCD trace
##   make clean - remove build artifacts

RTL_DIR    := $(abspath ../..)
LIBS_DIR   := $(RTL_DIR)/libs
IFC_DIR    := $(RTL_DIR)/interfaces
TCU_DIR    := $(RTL_DIR)/tcu
CORE_DIR   := $(RTL_DIR)/core
FPU_DIR    := $(RTL_DIR)/fpu

VERILATOR := verilator

# --------------------------------------------------------------------------
# RTL source files
# --------------------------------------------------------------------------

## 1. Packages
PKG_SRCS := \
    $(RTL_DIR)/VX_gpu_pkg.sv      \
    $(FPU_DIR)/VX_fpu_pkg.sv      \
    $(TCU_DIR)/VX_tcu_pkg.sv

## 2. Interfaces used by VX_schedule
IFC_SRCS := \
    $(IFC_DIR)/VX_schedule_if.sv        \
    $(IFC_DIR)/VX_warp_ctl_if.sv        \
    $(IFC_DIR)/VX_branch_ctl_if.sv      \
    $(IFC_DIR)/VX_decode_sched_if.sv    \
    $(IFC_DIR)/VX_issue_sched_if.sv     \
    $(IFC_DIR)/VX_commit_sched_if.sv    \
    $(IFC_DIR)/VX_sched_csr_if.sv

## 3. Library primitives
LIB_SRCS := \
    $(LIBS_DIR)/VX_pipe_register.sv     \
    $(LIBS_DIR)/VX_shift_register.sv    \
    $(LIBS_DIR)/VX_elastic_buffer.sv    \
    $(LIBS_DIR)/VX_pending_size.sv      \
    $(LIBS_DIR)/VX_dp_ram.sv            \
    $(LIBS_DIR)/VX_priority_encoder.sv  \
    $(LIBS_DIR)/VX_fifo_queue.sv

## 4. Core modules used by VX_schedule
CORE_SRCS := \
    $(CORE_DIR)/VX_ipdom_stack.sv       \
    $(CORE_DIR)/VX_split_join.sv        \
    $(CORE_DIR)/VX_uuid_gen.sv          \
    $(CORE_DIR)/VX_schedule.sv

RTL_SRCS := $(PKG_SRCS) $(IFC_SRCS) $(LIB_SRCS) $(CORE_SRCS)

# --------------------------------------------------------------------------
# Testbench sources
# --------------------------------------------------------------------------
TB_SRC  := tb_schedule.sv
TB_MAIN := main.cpp

BUILD_DIR := obj_dir
TARGET    := $(BUILD_DIR)/Vtb_schedule
VCD_FILE  := wave_schedule.vcd

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
VL_FLAGS  += -Wno-GENUNNAMED -Wno-IMPORTSTAR -Wno-VARHIDDEN

# Stability fix: prevent Verilator 5.028 coroutine crash
VL_FLAGS  += --x-initial unique --x-assign unique
VL_FLAGS  += --output-split 1000000
VL_FLAGS  += --output-split-cfuncs 1000000
VL_FLAGS  += --CFLAGS "-g -O0"
VL_FLAGS  += --timescale-override 1ns/1ns

# Preprocessor defines
VL_FLAGS  += -DSIMULATION
VL_FLAGS  += -DXLEN_32
VL_FLAGS  += -DEXT_TCU_ENABLE
VL_FLAGS  += -DEXT_AG_TCU_ENABLE
VL_FLAGS  += -DTCU_BHF
VL_FLAGS  += -DL1_ENABLE

# Include paths
VL_FLAGS  += -I$(RTL_DIR)
VL_FLAGS  += -I$(LIBS_DIR)
VL_FLAGS  += -I$(IFC_DIR)
VL_FLAGS  += -I$(TCU_DIR)
VL_FLAGS  += -I$(FPU_DIR)
VL_FLAGS  += -I$(CORE_DIR)

# Top module and output directory
VL_FLAGS  += --top-module tb_schedule
VL_FLAGS  += --Mdir $(BUILD_DIR)
VL_FLAGS  += -o Vtb_schedule

# --------------------------------------------------------------------------
# Vivado xsim flow (make gui → WDB + Vivado waveform viewer)
# --------------------------------------------------------------------------
XVLOG     := xvlog
XELAB     := xelab
XSIM      := xsim

XSIM_DIR  := xsim_proj
XSIM_SNAP := tb_schedule_snap

# xvlog flags: mirror Verilator defines and include paths
XV_FLAGS  := --sv
XV_FLAGS  += -d SIMULATION -d XLEN_32
XV_FLAGS  += -d EXT_TCU_ENABLE -d EXT_AG_TCU_ENABLE -d TCU_BHF -d L1_ENABLE
XV_FLAGS  += -i $(RTL_DIR) -i $(LIBS_DIR) -i $(IFC_DIR)
XV_FLAGS  += -i $(TCU_DIR) -i $(FPU_DIR) -i $(CORE_DIR)

# All lib primitives — xvlog requires explicit file listing (unlike Verilator)
LIB_SRCS_ALL := $(wildcard $(LIBS_DIR)/*.sv)

# Compile + elaborate stamp
$(XSIM_DIR)/$(XSIM_SNAP).sim: $(TB_SRC) $(RTL_SRCS)
	mkdir -p $(XSIM_DIR)
	cd $(XSIM_DIR) && $(XVLOG) $(XV_FLAGS) $(PKG_SRCS) $(IFC_SRCS) $(LIB_SRCS_ALL) $(CORE_SRCS) $(CURDIR)/$(TB_SRC)
	cd $(XSIM_DIR) && $(XELAB) --debug all --snapshot $(XSIM_SNAP) tb_schedule
	@touch $@

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
.PHONY: all run wave gui clean

all: run

$(TARGET): $(TB_SRC) $(TB_MAIN) $(RTL_SRCS)
	$(VERILATOR) $(VL_FLAGS) $(RTL_SRCS) $(TB_SRC) $(TB_MAIN)

run: $(TARGET)
	@echo "==== Running Level 9: VX_schedule Testbench ===="
	$(TARGET)

wave: $(TARGET)
	@echo "==== Running with VCD trace ===="
	$(TARGET) +trace=$(VCD_FILE)
	@echo "Waveform written to $(VCD_FILE)"

# Open Vivado xsim GUI; WDB saved as xsim_proj/tb_schedule_snap.wdb
gui: $(XSIM_DIR)/$(XSIM_SNAP).sim
	@echo "==== Vivado xsim GUI (tb_schedule) ===="
	@echo "     WDB: $(XSIM_DIR)/$(XSIM_SNAP).wdb"
	cd $(XSIM_DIR) && $(XSIM) $(XSIM_SNAP) --gui \
	    --tclbatch $(CURDIR)/gui_xsim.tcl

clean:
	rm -rf $(BUILD_DIR) $(VCD_FILE) $(XSIM_DIR) xsim.log xelab.log *.jou *.pb
