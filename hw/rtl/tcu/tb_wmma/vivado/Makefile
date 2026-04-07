## Makefile — Vivado xsim simulation for tb_tcu_wmma
##
## Simulate targets (pass/fail 확인):
##   make simulate / test-all  - 전 포맷
##   make test-int8            - INT8 only
##   make test-mxint8          - MXINT8 only
##   make test-mx9             - MX9 only
##   make test-flat            - FLAT only
##   make test-fp8             - MXFP8 (FP8 E4M3/E5M2) only
##   make nt8                  - 전 포맷, NT=8
##
## GUI targets (Vivado Waveform Viewer):
##   make gui                  - 전 포맷 GUI
##   make gui-int8             - INT8 GUI
##   make gui-mxint8           - MXINT8 GUI
##   make gui-mx9              - MX9 GUI
##   make gui-flat             - FLAT GUI
##   make gui-fp8              - MXFP8 GUI
##
## Build targets:
##   make compile              - 소스 컴파일만
##   make elaborate            - elaborate (xelab)
##   make clean                - 빌드 산출물 제거
##
## 출력:
##   waveform.vcd              - GTKWave 또는 Vivado에서 열기 가능
##   xsim.dir/                 - xsim 내부 라이브러리

# --------------------------------------------------------------------------
# Vivado bin path (설치 경로에 맞게 수정)
# --------------------------------------------------------------------------
VIVADO_BIN := /opt/xilinx/Vivado/2023.1/bin
XVLOG      := $(VIVADO_BIN)/xvlog
XELAB      := $(VIVADO_BIN)/xelab
XSIM       := $(VIVADO_BIN)/xsim

# --------------------------------------------------------------------------
# Source paths (tb_wmma/vivado/ → tb_wmma/ → tcu/ → rtl/)
# --------------------------------------------------------------------------
TB_DIR   := $(abspath ..)
RTL_DIR  := $(abspath ../../..)
LIBS_DIR := $(RTL_DIR)/libs
IFC_DIR  := $(RTL_DIR)/interfaces
TCU_DIR  := $(RTL_DIR)/tcu
BHF_DIR  := $(TCU_DIR)/bhf
CORE_DIR := $(RTL_DIR)/core
HF_DIR   := $(abspath ../../../../..)/third_party/hardfloat/source

# --------------------------------------------------------------------------
# RTL source files (컴파일 순서 중요: package → interface → lib → module)
# --------------------------------------------------------------------------
PKG_SRCS := \
    $(RTL_DIR)/VX_gpu_pkg.sv    \
    $(TCU_DIR)/VX_tcu_pkg.sv

IFC_SRCS := \
    $(IFC_DIR)/VX_dispatch_if.sv  \
    $(IFC_DIR)/VX_commit_if.sv    \
    $(IFC_DIR)/VX_execute_if.sv   \
    $(IFC_DIR)/VX_result_if.sv

# Include all libs to avoid hunting individual dependencies
LIB_SRCS := $(wildcard $(LIBS_DIR)/*.sv)

CORE_SRCS := \
    $(CORE_DIR)/VX_dispatch_unit.sv  \
    $(CORE_DIR)/VX_pe_switch.sv      \
    $(CORE_DIR)/VX_gather_unit.sv

HF_SRCS := \
    $(HF_DIR)/HardFloat_primitives.v    \
    $(HF_DIR)/HardFloat_rawFN.v         \
    $(HF_DIR)/isSigNaNRecFN.v           \
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
    $(TCU_DIR)/VX_tcu_fedp_int.sv              \
    $(TCU_DIR)/VX_tcu_fedp_int_scaled.sv       \
    $(TCU_DIR)/VX_tcu_scale_ctx.sv             \
    $(TCU_DIR)/VX_tcu_micro_ctx.sv             \
    $(TCU_DIR)/VX_tcu_operand_transformer.sv   \
    $(TCU_DIR)/VX_tcu_fp.sv                    \
    $(TCU_DIR)/VX_tcu_int.sv                   \
    $(TCU_DIR)/VX_tcu_unit.sv

TB_SRC      := $(TB_DIR)/tb_tcu_wmma.sv
TB_DEMO_SRC := $(TB_DIR)/tb_tcu_demo.sv
SNAP_DEMO   := tb_tcu_demo_snap

# --------------------------------------------------------------------------
# Preprocessor defines
# --------------------------------------------------------------------------
DEFINES := \
    -d SIMULATION   \
    -d XLEN_32      \
    -d EXT_TCU_ENABLE   \
    -d EXT_AG_TCU_ENABLE \
    -d TCU_BHF

# 테스트 그룹 추가 (make test-safe 등에서 자동 설정)
DEFINES += $(DEFINES_EXTRA)

# --------------------------------------------------------------------------
# Include paths
# --------------------------------------------------------------------------
INCS := \
    -i $(RTL_DIR)    \
    -i $(LIBS_DIR)   \
    -i $(IFC_DIR)    \
    -i $(TCU_DIR)    \
    -i $(BHF_DIR)    \
    -i $(HF_DIR)     \
    -i $(HF_DIR)/RISCV \
    -i $(CORE_DIR)   \
    -i $(TB_DIR)

# --------------------------------------------------------------------------
# xelab snapshot name
# --------------------------------------------------------------------------
SNAP     := tb_tcu_wmma_snap
VCD_FILE := waveform.vcd

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
.PHONY: all simulate gui compile elaborate clean \
        test-all test-safe test-int8 test-mxint8 test-mx9 test-flat test-fp8 test-mxfp8 test-3level \
        gui-int8 gui-mxint8 gui-mx9 gui-flat gui-fp8 gui-mxfp8 gui-3level \
        compile-demo elaborate-demo gui-demo \
        nt8 test-safe-nt8

all: simulate

# 1단계: 컴파일
# HardFloat .v 파일은 --sv 없이, SV 파일은 --sv 로 컴파일
compile:
	@echo "=== [1/3] Compiling HardFloat sources (Verilog-2001) ==="
	$(XVLOG) $(DEFINES) $(INCS) $(HF_SRCS)
	@echo "=== [1/3] Compiling SystemVerilog sources ==="
	$(XVLOG) --sv $(DEFINES) $(INCS) \
	    $(PKG_SRCS) $(IFC_SRCS) $(LIB_SRCS) $(BHF_SRCS) $(CORE_SRCS) $(TCU_SRCS) $(TB_SRC)

# 2단계: Elaborate
elaborate: compile
	@echo "=== [2/3] Elaborating ==="
	$(XELAB) --debug typical --snapshot $(SNAP) --timescale 1ns/1ps tb_tcu_wmma

# 3단계: 시뮬레이션 (VCD 생성)
simulate: elaborate
	@echo "=== [3/3] Running simulation (VCD: $(VCD_FILE)) ==="
	$(XSIM) $(SNAP) -tclbatch xsim_run.tcl
	@echo "=== VCD written: $(VCD_FILE) ==="
	@echo "=== Open with: gtkwave $(VCD_FILE) ==="

# GUI 모드 (Vivado Waveform viewer)
gui: elaborate
	@echo "=== Opening Vivado Waveform GUI ==="
	$(XSIM) $(SNAP) -gui -tclbatch xsim_wave_gui.tcl

clean:
	rm -rf xsim.dir *.log *.jou *.pb $(VCD_FILE) *.wdb xelab.* xvlog.*

# --------------------------------------------------------------------------
# Demo testbench (tb_tcu_demo) — 교수님 waveform 검증용
# --------------------------------------------------------------------------
compile-demo:
	@echo "=== [1/3] Compiling HardFloat sources ==="
	$(XVLOG) $(DEFINES) $(INCS) $(HF_SRCS)
	@echo "=== [1/3] Compiling SystemVerilog sources (demo TB) ==="
	$(XVLOG) --sv $(DEFINES) $(INCS) \
	    $(PKG_SRCS) $(IFC_SRCS) $(LIB_SRCS) $(BHF_SRCS) $(CORE_SRCS) $(TCU_SRCS) $(TB_DEMO_SRC)

elaborate-demo: compile-demo
	@echo "=== [2/3] Elaborating demo snapshot ==="
	$(XELAB) --debug typical --snapshot $(SNAP_DEMO) --timescale 1ns/1ps tb_tcu_demo

# gui-demo: 3 시나리오 waveform (INT8 / MXINT8 / 3LEVEL)
gui-demo:
	$(MAKE) clean
	$(MAKE) elaborate-demo
	@echo "=== Opening Demo Waveform ==="
	$(XSIM) $(SNAP_DEMO) -gui -tclbatch xsim_wave_demo.tcl

# --------------------------------------------------------------------------
# 포맷별 테스트 타겟 (Verilator Makefile과 동일한 인터페이스)
# --------------------------------------------------------------------------
test-all test-safe:
	$(MAKE) clean
	$(MAKE) simulate

test-int8:
	$(MAKE) clean
	$(MAKE) simulate DEFINES_EXTRA="-d TCU_TEST_INT8"

test-mxint8:
	$(MAKE) clean
	$(MAKE) simulate DEFINES_EXTRA="-d TCU_TEST_MXINT8"

test-mx9:
	$(MAKE) clean
	$(MAKE) simulate DEFINES_EXTRA="-d TCU_TEST_MX9"

test-flat:
	$(MAKE) clean
	$(MAKE) simulate DEFINES_EXTRA="-d TCU_TEST_FLAT"

test-fp8:
	$(MAKE) clean
	$(MAKE) simulate DEFINES_EXTRA="-d TCU_TEST_FP8"

test-mxfp8:
	$(MAKE) clean
	$(MAKE) simulate DEFINES_EXTRA="-d TCU_TEST_MXFP8"

test-3level:
	$(MAKE) clean
	$(MAKE) simulate DEFINES_EXTRA="-d TCU_TEST_3LEVEL"

# --------------------------------------------------------------------------
# 포맷별 GUI 타겟 — waveform 디버깅용
# --------------------------------------------------------------------------
gui-int8:
	$(MAKE) clean
	$(MAKE) gui DEFINES_EXTRA="-d TCU_TEST_INT8"

gui-mxint8:
	$(MAKE) clean
	$(MAKE) gui DEFINES_EXTRA="-d TCU_TEST_MXINT8"

gui-mx9:
	$(MAKE) clean
	$(MAKE) gui DEFINES_EXTRA="-d TCU_TEST_MX9"

gui-flat:
	$(MAKE) clean
	$(MAKE) gui DEFINES_EXTRA="-d TCU_TEST_FLAT"

gui-fp8:
	$(MAKE) clean
	$(MAKE) gui DEFINES_EXTRA="-d TCU_TEST_FP8"

gui-mxfp8:
	$(MAKE) clean
	$(MAKE) gui DEFINES_EXTRA="-d TCU_TEST_MXFP8"

gui-3level:
	$(MAKE) clean
	$(MAKE) gui DEFINES_EXTRA="-d TCU_TEST_3LEVEL"

# --------------------------------------------------------------------------
# NT=8 variants
# --------------------------------------------------------------------------
nt8:
	$(MAKE) clean
	$(MAKE) simulate DEFINES_EXTRA="-d NUM_THREADS=8"

test-safe-nt8:
	$(MAKE) clean
	$(MAKE) simulate DEFINES_EXTRA="-d NUM_THREADS=8"
