# =============================================================================
# xsim_wave_demo.tcl — AG-TCU Demo Waveform Configuration
# =============================================================================
# Usage: xsim tb_tcu_demo_snap -gui -tclbatch xsim_wave_demo.tcl
#
# 신호를 5개 그룹으로 구성:
#   [1] Demo Control    — 현재 시나리오 번호 (demo_phase)
#   [2] Dispatch Input  — TCU로 전송되는 명령어 및 데이터 (OT 이전)
#   [3] OT Output       — Operand Transformer 출력 (1 cycle 뒤, flatten 결과)
#   [4] Commit Result   — 최종 FP32 연산 결과
#   [5] DUT Hierarchy   — DUT 전체 신호 (상세 분석용)
#
# ─── 핵심 관측 포인트 (Scenario 3: 3LEVEL) ──────────────────────────────────
#   Dispatch:  rs1_data[0] = 0x02020101   (raw A, pair1≠pair0)
#              fmt_s       = 3 (TCU_3LEVEL_ID)
#              tcu_op      = 0 (WMMA)
#   OT Output: rs1_data[0] = 0x08080202   (flatten: pair0<<1, pair1<<2) ←KEY
#              fmt_s       = 9 (TCU_I8_ID) ← OT가 패치
#   Commit:    data[0]     = 0x43900000   (FP32 288.0)
# =============================================================================

# ─── [1] Demo Control ─────────────────────────────────────────────────────
add_wave_divider "━━━ [1] Demo Control ━━━"
add_wave /tb_tcu_demo/clk
add_wave /tb_tcu_demo/reset
add_wave -radix unsigned /tb_tcu_demo/demo_phase
add_wave -radix unsigned /tb_tcu_demo/pass_cnt
add_wave -radix unsigned /tb_tcu_demo/fail_cnt

# ─── [2] Dispatch Input (OT 이전 — raw operand) ─────────────────────────
add_wave_divider "━━━ [2] Dispatch Input (raw, before OT) ━━━"
add_wave /tb_tcu_demo/dispatch_if[0]/valid
add_wave /tb_tcu_demo/dispatch_if[0]/ready

# Instruction type and format
add_wave -radix hexadecimal /tb_tcu_demo/dispatch_if[0]/data/op_args/tcu/tcu_op
add_wave -radix hexadecimal /tb_tcu_demo/dispatch_if[0]/data/op_args/tcu/fmt_s
# fmt_s key: 0=FP32, 1=FP16, 2=BF16, 3=3LEVEL, 4=MX9, 8=I32, 9=I8, 13=MXINT8

# A operand (thread 0 tile word 0) — watch this transform in Scenario 3
add_wave -radix hexadecimal /tb_tcu_demo/dispatch_if[0]/data/rs1_data[0]
# B operand
add_wave -radix hexadecimal /tb_tcu_demo/dispatch_if[0]/data/rs2_data[0]
# C accumulator (should be 0 for first UOP)
add_wave -radix hexadecimal /tb_tcu_demo/dispatch_if[0]/data/rs3_data[0]

# ─── [3] OT Output (1 cycle after Dispatch — flattened operand) ──────────
add_wave_divider "━━━ [3] OT Output (flattened, 1 cy after Dispatch) ━━━"
# NOTE: Navigate in hierarchy panel:
#   tb_tcu_demo > dut > g_blocks[0] > ot_execute_if
# or use the paths below (Vivado xsim generate scope naming may vary):
add_wave /tb_tcu_demo/dut/g_blocks[0]/ot_execute_if/valid
# fmt_s AFTER OT: 3LEVEL(3) is patched to I8(9) by OT
add_wave -radix hexadecimal /tb_tcu_demo/dut/g_blocks[0]/ot_execute_if/data/op_args/tcu/fmt_s
# A operand AFTER OT flatten — compare with Dispatch rs1_data[0] above
add_wave -radix hexadecimal /tb_tcu_demo/dut/g_blocks[0]/ot_execute_if/data/rs1_data[0]
# B operand AFTER OT flatten
add_wave -radix hexadecimal /tb_tcu_demo/dut/g_blocks[0]/ot_execute_if/data/rs2_data[0]
# PE selector: 0=FP path, 1=INT path
add_wave /tb_tcu_demo/dut/g_blocks[0]/pe_sel_w

# ─── [4] Commit Result ────────────────────────────────────────────────────
add_wave_divider "━━━ [4] Commit Result (FP32 output) ━━━"
add_wave /tb_tcu_demo/commit_if[0]/valid
# FP32 result — Scenario 1: 0x41800000 (16.0)
#               Scenario 2: 0x42000000 (32.0)
#               Scenario 3: 0x43900000 (288.0)
add_wave -radix hexadecimal /tb_tcu_demo/commit_if[0]/data/data[0]
add_wave -radix hexadecimal /tb_tcu_demo/commit_if[0]/data/data[1]
add_wave -radix hexadecimal /tb_tcu_demo/commit_if[0]/data/data[2]
add_wave -radix hexadecimal /tb_tcu_demo/commit_if[0]/data/data[3]

# ─── [5] DUT Full Hierarchy (상세 분석용) ────────────────────────────────
add_wave_divider "━━━ [5] DUT Internal (상세 분석) ━━━"
add_wave_divider "  OT Internal"
add_wave -recursive /tb_tcu_demo/dut/g_blocks[0]/operand_xformer
add_wave_divider "  INT Path (VX_tcu_int)"
add_wave -recursive /tb_tcu_demo/dut/g_blocks[0]/tcu_int
add_wave_divider "  FP Path (VX_tcu_fp)"
add_wave -recursive /tb_tcu_demo/dut/g_blocks[0]/tcu_fp

# ─── Run & View ────────────────────────────────────────────────────────────
run all
wave zoom full
