# =============================================================================
# xsim_wave_demo.tcl — AG-TCU Demo Waveform Configuration
# =============================================================================
# Usage: xsim tb_tcu_demo_snap -gui -tclbatch xsim_wave_demo.tcl
#
# 신호를 6개 그룹으로 구성:
#   [1] Demo Control    — 시나리오 번호, pass/fail
#   [2] Dispatch: Word  — 32-bit 단위 dispatch 신호 (instruction, format)
#   [3] Dispatch: Bytes — A/B operand byte 단위 분해 (OT 이전 raw 값)
#   [4] OT Output: Bytes— A/B operand byte 단위 분해 (OT 이후 flatten 값)
#                         ← Scenario 3 핵심: pair0/pair1 shift 차이 확인
#   [5] Commit Result   — 4개 출력 element (D[0][0]~D[1][1])
#   [6] DUT Hierarchy   — 상세 분석용 (OT 내부, INT/FP path)
#
# ─── Scenario 3 (3LEVEL): 핵심 관측 ─────────────────────────────────────
#  Dispatch bytes:          OT output bytes:
#    disp_a_b0 = 0x01   →    ot_a_b0 = 0x02  (pair0 << 1)
#    disp_a_b1 = 0x01   →    ot_a_b1 = 0x02
#    disp_a_b2 = 0x02   →    ot_a_b2 = 0x08  (pair1 << 2, different!)
#    disp_a_b3 = 0x02   →    ot_a_b3 = 0x08
#  OT fmt_s:  3 (3LEVEL) →  9 (I8_ID)  ← OT가 패치
#  Result: result_0 ~ result_3 = 0x43900000 (FP32 288.0, NT=4)
# =============================================================================

# ─── [1] Demo Control ─────────────────────────────────────────────────────
add_wave_divider "━━━━━━ [1] Demo Control ━━━━━━"
add_wave /tb_tcu_demo/clk
add_wave /tb_tcu_demo/reset
add_wave -radix unsigned -color yellow /tb_tcu_demo/demo_phase
add_wave -radix unsigned /tb_tcu_demo/pass_cnt
add_wave -radix unsigned /tb_tcu_demo/fail_cnt

# ─── [2] Dispatch: Word-level (instruction) ───────────────────────────────
add_wave_divider "━━━━━━ [2] Dispatch — Word Level (instruction) ━━━━━━"
add_wave /tb_tcu_demo/dispatch_if[0]/valid
add_wave /tb_tcu_demo/dispatch_if[0]/ready
# tcu_op: 0=WMMA, 1=LDSCALE, 2=LDTILE, 3=LDMICRO, 4=FLAT
add_wave -radix unsigned /tb_tcu_demo/disp_tcu_op
# fmt_s: 0=FP32, 1=FP16, 2=BF16, 3=3LEVEL, 4=MX9, 8=I32, 9=I8(INT), 13=MXINT8
add_wave -radix unsigned /tb_tcu_demo/disp_fmt_s

# ─── [3] Dispatch: Byte-level (OT 이전 raw A/B operand) ──────────────────
add_wave_divider "━━━━━━ [3] Dispatch Bytes — OT 입력 (raw operand, word0) ━━━━━━"
add_wave_divider "  A operand (rs1_data[0])  ← pair0=[b1:b0], pair1=[b3:b2]"
add_wave -radix unsigned /tb_tcu_demo/disp_a_b0
add_wave -radix unsigned /tb_tcu_demo/disp_a_b1
add_wave -radix unsigned /tb_tcu_demo/disp_a_b2
add_wave -radix unsigned /tb_tcu_demo/disp_a_b3
add_wave_divider "  B operand (rs2_data[0])"
add_wave -radix unsigned /tb_tcu_demo/disp_b_b0
add_wave -radix unsigned /tb_tcu_demo/disp_b_b1
add_wave -radix unsigned /tb_tcu_demo/disp_b_b2
add_wave -radix unsigned /tb_tcu_demo/disp_b_b3

# ─── [4] OT Output: Byte-level (Operand Transformer 출력, 1 cy 뒤) ───────
add_wave_divider "━━━━━━ [4] OT Output Bytes — 1 cy 뒤 flatten 결과 ━━━━━━"
add_wave /tb_tcu_demo/ot_valid
# fmt_s AFTER OT: 3LEVEL(3) → I8(9) 패치 확인
add_wave -radix unsigned -color cyan /tb_tcu_demo/ot_fmt_s
add_wave -radix unsigned /tb_tcu_demo/ot_tcu_op
# PE selector: 0=FP path, 1=INT path
add_wave -radix unsigned /tb_tcu_demo/pe_sel
add_wave_divider "  Flattened A (ot_a_bX) — compare with disp_a_bX above"
# Scenario 3 expected: b0,b1=0x02 (pair0<<1), b2,b3=0x08 (pair1<<2)
add_wave -radix unsigned -color cyan /tb_tcu_demo/ot_a_b0
add_wave -radix unsigned -color cyan /tb_tcu_demo/ot_a_b1
add_wave -radix unsigned -color cyan /tb_tcu_demo/ot_a_b2
add_wave -radix unsigned -color cyan /tb_tcu_demo/ot_a_b3
add_wave_divider "  Flattened B (ot_b_bX)"
add_wave -radix unsigned /tb_tcu_demo/ot_b_b0
add_wave -radix unsigned /tb_tcu_demo/ot_b_b1
add_wave -radix unsigned /tb_tcu_demo/ot_b_b2
add_wave -radix unsigned /tb_tcu_demo/ot_b_b3

# ─── [5] Commit Result: 4 output elements ────────────────────────────────
add_wave_divider "━━━━━━ [5] Commit — 4 Output Elements (FP32) ━━━━━━"
add_wave /tb_tcu_demo/commit_if[0]/valid
# D[0][0] ~ D[1][1]: all should be equal for uniform A,B
# Sc1: 0x41800000 (16.0), Sc2: 0x42000000 (32.0), Sc3: 0x43900000 (288.0)
add_wave -radix hexadecimal -color yellow /tb_tcu_demo/result_0
add_wave -radix hexadecimal /tb_tcu_demo/result_1
add_wave -radix hexadecimal /tb_tcu_demo/result_2
add_wave -radix hexadecimal /tb_tcu_demo/result_3

# ─── [6] DUT Hierarchy (상세 분석용) ─────────────────────────────────────
add_wave_divider "━━━━━━ [6] DUT Internal (상세 분석) ━━━━━━"
add_wave_divider "  Operand Transformer (VX_tcu_operand_transformer)"
add_wave -recursive /tb_tcu_demo/dut/g_blocks[0]/operand_xformer
add_wave_divider "  INT Path — VX_tcu_int (FEDP, 6 cy)"
add_wave -recursive /tb_tcu_demo/dut/g_blocks[0]/tcu_int
add_wave_divider "  FP Path — VX_tcu_fp (FEDP, 14 cy)"
add_wave -recursive /tb_tcu_demo/dut/g_blocks[0]/tcu_fp

# ─── Run & View ───────────────────────────────────────────────────────────
run all
wave zoom full
