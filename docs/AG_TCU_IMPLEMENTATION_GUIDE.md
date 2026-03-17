# AG-TCU Implementation Guide
## Avant-Garde 논문 기반 Microscaled Block-Floating Tensor Core 구현 계획

---

## 0. 문서 목적 및 구현 방향 결정

이 가이드는 Avant-Garde 논문 구조를 목표로 AG-TCU를 구현하는 계획서이다.
RTL과 문서 목표가 다를 경우의 방향 결정을 아래에 명시한다.

| 차이점 | 방향 결정 | 근거 | 상태 |
|--------|---------|------|------|
| Flatten 패러다임 (LDSCALE → HW-transparent) | **문서 따름** → RTL 수정 | 논문 핵심 원칙 | ✅ Stage 1 완료, Stage 2 예정 |
| exp bitwidth (4-bit → E8M0 8-bit) | **E8M0 구현** | microscaling 표준 | ✅ Phase 5 완료 |
| Negative exponent 지원 | **문서 따름** | Microscaling 일반성 | ✅ Phase 4①+② 완료 |
| Shift clamp 정책 | **문서 따름** | 안전성 | ✅ 완료 |
| Block-Scaled memory format (LDTILE) | **문서 따름** | HW-transparent load | ✅ Phase 4④ 완료 |

---

## 1. Target Architecture 전체 파이프라인

GPU 실행 순서 기준:

```
[1] Instruction Fetch / Decode
     LDTILE rs1          → tile registers (f0–f7 등)에 INT8 데이터 로드 (HW-transparent)
     LDSCALE rs1         → scale_ctx[wid] 업데이트 (E8M0)
     AG_TCU_WMMA rd, rs1, rs2, rs3
     (scale는 instruction 없음 — Scale Context Register에서 HW 자동 조회)
          │
          ▼
[2] Issue / Scoreboard  (PIPE_LATENCY = 5 사이클)
          │
          ▼
[3] Register Read
     rs1, rs2, rs3 → Warp Register File (tile registers)
     scale_a, scale_b → Scale Context Register (per-warp, 2-port, E8M0)
          │
          ▼
[4] Flatten Stage (VX_tcu_int)
     ┌────────────────────────────────────────────────────────────┐
     │ LDSCALE: scale_ctx[wid] 기록 (E8M0 8-bit, bias=127)       │
     │ LDTILE:  A/B/C zeroed → FEDP NOP (tile data via FLW)      │
     │ WMMA: exp_total = scale_a[wid] + scale_b[wid] - 254       │
     │       (signed 10-bit, range [-254, +256])                 │
     └────────────────────────────────────────────────────────────┘
          │
          ▼
[5] Tensor Core (VX_tcu_fedp_int_scaled)
     ├── Exponent Combine: exp_total (10-bit signed)
     ├── Mantissa MAC: dot = Σ int8(a) × int8(b)
     ├── Bidirectional Shift: exp_total≥0 → dot<<<exp | exp_total<0 → dot>>>|exp|
     ├── Shift Clamp: exp>30 → saturate, exp<-31 → flush to 0
     ├── Saturation: clip to INT32
     └── Accumulator: d = partial_sat + c  (wrapping)
          │
          ▼
[6] Writeback (rd)
```

---

## 2. Scale Context Register File

### 2.1 현재 RTL 구현 (VX_tcu_scale_ctx.sv)

```
Scale Context Register File:
  구조: per-logical-warp, 2-port
  ├── Port A: scale_a (8-bit E8M0 unsigned, bias=127, neutral=127)
  └── Port B: scale_b (8-bit E8M0 unsigned, bias=127, neutral=127)
  용량: NUM_WARPS × 2 entry × 8-bit

Read:  combinational by wid (WMMA dispatch 시)
Write: synchronous by LDSCALE execute_fire
```

### 2.2 exp 표현 방식 (현재 — E8M0)

| 항목 | Phase 4①+② (구버전) | **현재 — E8M0 (Phase 5)** |
|------|---------------------|--------------------------|
| bitwidth | 4-bit **signed** per side | **8-bit E8M0 unsigned** (bias=127) |
| 의미 | 직접 signed shift amount | `value = m × 2^(exp−127)` |
| exp_total 공식 | `scale_a + scale_b` (signed) | `scale_a + scale_b − 254` |
| exp_total 범위 | signed 5-bit **[-16, +14]** | signed 10-bit **[-254, +256]** |
| 음수 exp | arithmetic right shift ✅ | arithmetic right shift ✅ |
| 중립값 | scale=0 | **scale_a=scale_b=127** |

### 2.3 Flatten Paradigm — 3단계 진행

#### Stage 0 — Full-SW (Avant-Garde flatten 이전)
```
# exp를 WMMA 패킷에 직접 포함
WMMA rd, rs1, rs2, rs3, exp_a, exp_b   # 매 instruction마다 exp 전달
```
→ `tcu_args_t`에 `exp_a(4b)+exp_b(4b)` 필드 존재. **현재 RTL에서 제거됨.**

#### Stage 1 — Semi-Flatten ✅ 현재 RTL
```
# 프로그래머가 LDSCALE / LDTILE을 명시적으로 발행
LDTILE rs1     # rs1_data[t] = 타일 베이스 주소 → tile registers f0–f7 (per thread)
LDSCALE rs1    # rs1_data[0][7:0]=scale_a, [15:8]=scale_b (E8M0) → scale_ctx[wid]
WMMA rd, rs1, rs2, rs3   # HW가 scale_ctx[wid] 자동 조회
```
- exp가 instruction packet에서 분리됨 (flatten 개념 도입)
- 타일 데이터 로드도 LDTILE로 명시적 발행 (HW-transparent: FLW 경로 이용)
- `tcu_op=LDSCALE`, `tcu_op=LDTILE` ISA 노출됨

#### Stage 2 — Full HW-Transparent Flatten → 향후 구현 예정
```
# 메모리 load 시 LSU가 block header 자동 파싱
LOAD rs1, [A_block_addr]  # HW: scale byte → scale_ctx[wid], mantissa → rs1
LOAD rs2, [B_block_addr]  # HW: scale byte → scale_ctx[wid], mantissa → rs2
WMMA rd, rs1, rs2, rs3   # 동일 (scale_ctx 자동 조회)
```
- **LDSCALE / LDTILE ISA 불필요** — 프로그래머에게 완전 투명
- Avant-Garde 논문 핵심 원칙 실현
- 수정 범위: LSU(load unit) + scale_ctx write 연동

| 항목 | Stage 0 | Stage 1 (현재) | Stage 2 (목표) |
|------|---------|---------------|---------------|
| scale 전달 방식 | WMMA 패킷 내 | LDSCALE 명시적 | LSU 자동 파싱 |
| tile load 방식 | N/A | LDTILE 명시적 | LSU 자동 파싱 |
| 프로그래머 부담 | 매 WMMA마다 | K-loop 전 1회 | 없음 |
| ISA 노출 | exp 필드 | LDSCALE + LDTILE | WMMA 하나만 |
| HW scale_ctx | 없음 | 있음 ✅ | 있음 |

### 2.4 Block-Scaled Memory Format (MX9, 현재 simx 모델)

```
// E8M0 기준 (Phase 5)
struct ScaledBlock {
    uint8_t scale_a_e8m0;  // A-matrix global exponent (E8M0, bias=127)
    uint8_t scale_b_e8m0;  // B-matrix global exponent (E8M0, bias=127)
    int8_t  mantissa[N];   // 플래튼된 INT8 elements (1-bit micro-exp 이미 적용)
};

// MX9 1-bit micro-exponent flatten:
//   flattened = saturate(element << micro_exp, -128, 127)
```

LDTILE (simx) execute pattern:
```
// 각 thread t: base_addr = rs1_data[t].u32
// reg_base: TILE_A→0, TILE_B→28, TILE_C→10 (NT=4 기준)
// n_words: NRA=8, NRB=4, NRC=8 (NT=4 기준)
for w in [0, n_words):
    warp.freg_file[reg_base + w][t] = nan_box(mem[base_addr + w*4])
```

---

## 3. Tensor Core 연산 모델

### 3.1 현재 연산 수식 (Phase 5 E8M0 기준)

```
scale_a, scale_b: uint8_t E8M0 unsigned [0, 255], bias=127
exp_total = (int)scale_a + (int)scale_b - 2×127   (signed 10-bit, [-254, +256])

dot = Σ_{k,b} int8(a[k][b]) × int8(b[k][b])       (TC_K × 4 쌍)

// Bidirectional Shift + Clamp
if exp_total > 30:  aligned = saturate_to_INT32(dot)   // left shift overflow → early sat
elif exp_total >= 0: aligned = dot <<< exp_total
elif exp_total >= -31: aligned = dot >>> (-exp_total)   // arithmetic right shift
else:               aligned = 0                         // flush to 0

partial_sat = clip(aligned, INT32_MIN, INT32_MAX)
d = partial_sat + c    (wrapping 32-bit add, 2차 포화 없음)
```

**주요 경계 값 (Phase 5 E8M0):**
| scale_a | scale_b | exp_total | 효과 |
|---------|---------|-----------|------|
| 127 | 127 | 0 | No shift (neutral) |
| 128 | 127 | 1 | ×2 |
| 134 | 134 | 14 | ×16384 |
| 157 | 127 | 30 | max left shift |
| 158 | 127 | 31 | → saturate (clamped to 30) |
| 125 | 127 | −2 | ÷4 (right shift 2) |
| 96 | 127 | −31 | min right shift |
| 95 | 127 | −32 | → flush to 0 (clamped) |

### 3.2 구현 이력

**Phase 4① — Signed Scale 전환 (4-bit)**:
- `scale_a`/`scale_b`: 4-bit unsigned [0,15] → **4-bit signed [-8, +7]**
- `exp_total` 범위: signed 5-bit [-16, +14]
- `VX_tcu_scale_ctx.sv`: 4-bit signed 저장

**Phase 4② — Bidirectional Shift**:
- `VX_tcu_fedp_int_scaled.sv`: signed exp_total, `is_rshift = exp[4]` (sign bit)
- `ALIGNED_W = REDW + 14` (최대 좌이동 14비트)
- simx: `ScaleContext` → `int8_t`; `ag_wmma` bidirectional 분기

**Phase 5 — E8M0 Scale Format ✅ 완료**:
- `scale_a`/`scale_b`: **8-bit E8M0 unsigned** [0,255], bias=127
- `exp_total` = `scale_a + scale_b − 254` (signed 10-bit, [-254, +256])
- `TCU_EXP_BITS=8`, `TCU_EXP_TOTAL=10`, `TCU_EXP_BIAS=127`
- ALIGNED_W = REDW + 30 (최대 좌이동 30비트)
- Shift clamp: exp>30 → 조기 포화, exp<-31 → flush to 0
- `VX_tcu_scale_ctx.sv`: 8-bit unsigned 저장
- simx: `ScaleContext` → `uint8_t`, init=127; exp_total = `(int)a + (int)b − 254`

**Phase 4③ — K-Iteration Hazard Lock ✅ 완료**:
- `ldscale_delay_pipe`: is_ldscale/is_ldtile을 FEDP 파이프라인과 동기화 추적
- `wmma_inflight[NUM_WARPS]`: warp별 in-flight WMMA uop 카운터
- `ldscale_hazard = (is_ldscale || is_ldtile) && wmma_inflight[wid] != 0` → 차단

**Phase 4④ — LDTILE HW-Transparent Block Load ✅ 완료**:
- ISA: `funct7[2:0]=3'b111, funct7[4:3]=tile_type, funct3=3'h0, INST_EXT1`
- RTL: `tcu_op_e` 2-bit 확장 + `tile_type[1:0]` 필드 → FEDP NOP 처리
- simx: execute.cpp에서 dcache_read → freg_file 직접 기록

### 3.3 K-Iteration Exponent 정책

```
제약: 동일 WMMA tile 내 모든 K-block은 동일한 scale_a, scale_b를 공유.
    → Scale Context Register가 K-loop 동안 고정됨.
    → exp_total이 k-block 간에 동일하므로 수학적으로 올바른 누산.

K-loop 최초 uop 전에 LDSCALE (또는 HW load) 한 번 실행.
K-loop 동안 Scale Context Register 덮어쓰기 금지.
    → Phase 4③: K-iteration hazard lock ✅ 구현됨
```

### 3.4 파이프라인 레이턴시 (TC_K=2 기준)

```
MUL_LATENCY  = 2
RED_LATENCY  = log2(TC_K) × 1 = 1
ACC_LATENCY  = RED_LATENCY + 1 = 2
FEDP_LATENCY = MUL_LATENCY + ACC_LATENCY = 4
PIPE_LATENCY = FEDP_LATENCY + 1 = 5  (scoreboard 기준)
```

---

## 4. rs2 Sub-Block Offset (B_SUB_BLOCKS)

```systemverilog
// VX_tcu_int.sv (현재 RTL)
b_off = (step_n & (TCU_B_SUB_BLOCKS-1)) << LG_B_BS

// NT=8: B_SUB_BLOCKS=2, LG_B_BS=2
// step_n=0,2 → b_off=0 (스레드 [0:3])
// step_n=1,3 → b_off=4 (스레드 [4:7])
```

---

## 5. 파라미터 참조

| 파라미터 | NT=4 | NT=8 | 비고 |
|---------|------|------|------|
| TILE_M / N / K | 8 / 4 / 4 | 8 / 8 / 8 | TILE_M = 2^TILE_EM |
| TC_M / N / K | 2 / 2 / 2 | 4 / 2 / 2 | |
| UOPS | 16 | 32 | M_STEPS × N_STEPS × K_STEPS |
| B_SUB_BLOCKS | 1 | 2 | |
| **TCU_EXP_BITS** | **8** | **8** | **E8M0 unsigned [0,255]** |
| **TCU_EXP_BIAS** | **127** | **127** | **E8M0 bias** |
| **TCU_EXP_TOTAL** | **10** | **10** | **signed 10-bit [-254,+256]** |
| PIPE_LATENCY | 5 | 5 | |
| NRA (A tile regs) | 8 | 8 | f0–f7 |
| NRB (B tile regs) | 4 | 8 | NT=4: f28–f31, NT=8: f10–f17 |
| NRC (C tile regs) | 8 | 8 | NT=4: f10–f17, NT=8: f24–f31 |

---

## 6. Instruction Encoding (RISC-V R-type, opcode=7'h0B)

| Instruction | funct7 | funct3 | rs2 | rs1 | rd | 비고 |
|-------------|--------|--------|-----|-----|-----|------|
| WMMA | `7'h02` | `3'h0` | rs2 | rs1[3:0]=fmt_s | rd[3:0]=fmt_d | `tcu_op=TCU_OP_WMMA (2'b00)` |
| LDSCALE | `7'h06` | `3'h0` | x0 | rs1=scale_reg | rd=x1 (wb=1) | `tcu_op=TCU_OP_LDSCALE (2'b01)` |
| LDTILE_A | `7'h07` | `3'h0` | x0 | rs1=addr_reg | — | `tcu_op=TCU_OP_LDTILE (2'b10), tile_type=0` |
| LDTILE_B | `7'h0F` | `3'h0` | x0 | rs1=addr_reg | — | `tcu_op=TCU_OP_LDTILE (2'b10), tile_type=1` |
| LDTILE_C | `7'h17` | `3'h0` | x0 | rs1=addr_reg | — | `tcu_op=TCU_OP_LDTILE (2'b10), tile_type=2` |

LDTILE funct7 구조: `funct7[2:0]=3'b111`, `funct7[4:3]=tile_type`, `funct7[6:5]=2'b00`

```systemverilog
// TB helper (tb_decode.sv 참조)
function automatic logic [31:0] encode_wmma(logic [3:0] fmt_d, logic [3:0] fmt_s);
    return {7'h02, 5'h0, {1'b0, fmt_s}, 3'h0, {1'b0, fmt_d}, 7'h0B};
endfunction

function automatic logic [31:0] encode_ldscale(logic [4:0] scale_rs1);
    return {7'h06, 5'h0, scale_rs1, 3'h0, 5'h1, 7'h0B};  // rd=x1
endfunction

// LDTILE: funct7[4:3]=tile_type, funct7[2:0]=3'b111
function automatic logic [31:0] encode_ldtile(logic [1:0] tile_type, logic [4:0] addr_rs1);
    return {{2'b00, tile_type, 3'b111}, 5'h0, addr_rs1, 3'h0, 5'h0, 7'h0B};
endfunction
```

### LDSCALE packing (E8M0)

```systemverilog
// rs1_data[0] = {16'b0, scale_b[7:0], scale_a[7:0]}
// 중립값 (exp_total=0): scale_a=scale_b=127 → 32'h7F7F
// exp_total=+2:  scale_a=129=0x81, scale_b=127=0x7F → 32'h7F81
preload_gpr(SCALE_REG, 32'h7F7F);  // neutral
preload_gpr(SCALE_REG, 32'h7F81);  // exp_total=+2
```

> **주의**: `rd=x0` (wb=0) 사용 시 VX_commit이 writeback_if.valid를 차단 →
> TB에서 commit 감지 불가. LDSCALE TB에서는 `rd=x1` 사용.

---

## 7. 구현 계획

### Phase 1 — simx 기본 Tensor Core ✅ 완료
- [x] `constants.h`: `AG_TCU_EXP_BITS`, `AG_TCU_EXP_TOTAL`, `AG_TCU_EXP_MAX/MIN`
- [x] `types.h`: `TcuType::LDSCALE`, `IntrTcuArgs::tcu_op` 필드
- [x] `tensor_unit.cpp`: `ag_wmma()` — INT8 MAC + shift + sat + wrapping acc
- [x] `tensor_unit.cpp`: `ScaleContext` — per-warp, 2-port, `ldscale()` write
- [x] `decode.cpp`: LDSCALE 디코딩, WMMA `tcu_op=0` 설정
- [x] `execute.cpp`: LDSCALE handler, WMMA → `ag_wmma()` 라우팅

### Phase 2 — simx Scale Context 모델 ✅ 완료
- [x] Scale Context Register (per-warp, 2-port) simx 모델
- [x] LDSCALE simx 에뮬레이션
- [x] `load_scaled_operand()`: `ScaledBlock` 파싱 → scale_ctx write + mantissa→ reg_data

### Phase 3 — simx 검증 ✅ 완료 (113/113 PASS)
- [x] exp_total 범위별 검증, shift clamp, wrapping acc, B sub-block offset

### Phase 4 — RTL 수정 (Flatten HW화)
- [x] **4①** signed scale (4-bit signed) ✅ 완료
- [x] **4②** bidirectional shift (음수 exp → arithmetic right shift) ✅ 완료
- [x] **4③** K-iteration hazard lock (`ldscale_delay_pipe`, `wmma_inflight`) ✅ 완료
  - L4 TC_hazard: 14/14 PASS (NT=4), 18/18 PASS (NT=8)
- [x] **4④** HW-Transparent Block Load (LDTILE) ✅ 완료
  - **Part A (simx)**: LDTILE decode (funct7=0x07/0x0F/0x17); execute.cpp에서 dcache_read → freg_file
  - **Part B (RTL)**: `tcu_op_e` 2-bit; `TCU_OP_LDTILE=2'b10`; `tile_type[1:0]` 필드;
    VX_decode LDTILE 경로; VX_uop_sequencer LDTILE 제외; VX_tcu_int NOP 처리;
    VX_tcu_unit pe_sel LDTILE → INT path

### Phase 5 — E8M0 Scale Format ✅ 완료
- [x] `TCU_EXP_BITS` 4-bit → **8-bit E8M0**
- [x] `TCU_EXP_BIAS = 127`, exp_total = `scale_a + scale_b − 254`
- [x] `TCU_EXP_TOTAL = 10` (signed 10-bit, [-254, +256])
- [x] ALIGNED_W = REDW + 30 (최대 좌이동 30비트)
- [x] Shift clamp: exp>30 → 조기 포화, exp<-31 → flush to 0
- [x] `VX_tcu_scale_ctx.sv`: 8-bit unsigned 저장/읽기
- [x] `VX_tcu_fedp_int_scaled.sv`: `parameter EXP_TOTAL=10`; 10-bit signed exp
- [x] simx: `ScaleContext` → `uint8_t`, init=127; LDSCALE 바이트 단위 디코딩
- [x] 모든 TB: `fire_ldscale(uint8_t, uint8_t)`, E8M0 packing `{16'b0, scale_b, scale_a}`
- [x] L7/L8: `SCALE_REG` preload `32'h7F7F` (neutral), `32'h7F81` (exp_total=+2)
- [x] `ScaledBlock`: `scale_a_e8m0`/`scale_b_e8m0` uint8_t 필드

### Phase 6 — 통합 검증 ✅ 완료
- [x] **6.1** `sgemm_ag_tcu` 커널 end-to-end 검증 (simx)
  - PASSED: exp=0 (neutral), exp=+2 (scale_a=129), exp=-1 (scale_a=126)
- [x] **6.2** `VX_tcu_operand_transformer.sv` 생성 — Flatten Stage 모듈 분리
  - `VX_tcu_int.sv` 리팩토링 (`result_wid_w` 픽스 포함)
  - tb_int 10/10 PASS, tb_wmma NT=4 20/20 PASS, NT=8 20/20 PASS
- [x] Stage 2 HW-transparent flatten 준비 (Phase 7 연속)

### Phase 7 — Operand Transformer 아키텍처 재설계 ✅ 완료
**Logical Flatten Only** — micro-exp × element HW 플래큰은 Phase 8

#### 변경 완료
- [x] `VX_gpu_pkg.sv`: `tcu_args_t`에 `exp_total` (signed 10-bit) 필드 추가 (Option B)
  - `__padding`: `INST_ARGS_BITS-20` → `INST_ARGS_BITS-30`
- [x] `VX_tcu_operand_transformer.sv`: wire-only sub-module → 1-cycle registered pipeline stage
  - VX_execute_if 슬레이브/마스터 인터페이스, exp_total을 payload에 latch
  - hazard 처리 (ldscale_hazard → execute_if_in.ready deassert)
  - feedback 포트: `fedp_enable`, `result_fire`, `result_wid` (from VX_tcu_int)
- [x] `VX_tcu_unit.sv`: `ot_execute_if` 삽입; pe_switch → OT → VX_tcu_int 연결
- [x] `VX_tcu_int.sv`: 내부 OT 제거; `execute_if.data.op_args.tcu.exp_total` 직접 읽기; `execute_if.ready` 단순화
- [x] Testbench 업데이트: tb_int exp_total 직접 설정, tb_unit/tb_wmma/tb_execute Makefile OT 소스 추가

#### 파이프라인 변화
```
[이전] FEDP(4cy) + mdata(1cy)  = PIPE_LATENCY=5
[Phase 7] OT(1cy) + FEDP(4cy) + mdata(1cy) = 총 6cy (scoreboard 기준)
```

#### 검증 결과 (Phase 7)
| TB | 결과 |
|----|------|
| tb_int | 10/10 PASS |
| tb_unit NT=4 | 14/14 PASS |
| tb_unit NT=8 | 18/18 PASS |
| tb_wmma NT=4 | 9/9 PASS |
| tb_wmma NT=8 | 5/5 PASS |
| tb_execute | 10/10 PASS |
| tb_issue | 5/5 PASS |
| tb_decode | 7/7 PASS |

#### 검증 결과 (Phase 8A)
| TB | 결과 |
|----|------|
| tb_int | 10/10 PASS |
| tb_unit NT=4 | 20/20 PASS (12기존 + 6 mexp + 2 hazard) |
| tb_unit NT=8 | 20/20 PASS |
| tb_wmma test-safe NT=4 | 9/9 PASS |
| tb_wmma test-safe NT=8 | 9/9 PASS |
| tb_wmma test-mexp NT=4 | 6/6 PASS |
| tb_wmma test-mexp NT=8 | 6/6 PASS |
| tb_execute | 10/10 PASS |
| tb_issue | 5/5 PASS |
| tb_decode | 7/7 PASS |

> **NT=8 Verilator 주의**: Phase 8A TCs는 `TESTS_MEXP` ifdef로 분리. `test-mexp-nt8` 타겟으로 실행.
> Verilator 5.028 coroutine split bug → NT=8에서 단일 initial block에 TC 과다 포함 시 deadlock.

#### Phase 7 OT 단계적 수행 (combinational 부분)
```
scale_ctx.read(wid) → rd_scale_a, rd_scale_b
exp_total = scale_a + scale_b − 254   (단일 LUT 체인, timing OK)
is_nop  = is_ldscale ‖ is_ldtile
ldscale_hazard = is_nop && wmma_inflight[wid] ≠ 0
```

#### Phase 7 OT 출력 (1-cycle registered)
```
ot_exe_data.exp_total ← exp_total (latch)
ot_exe_data.rs1_data  ← is_nop ? '0 : pe_rs1  (zero-gate)
ot_exe_data.rs2_data  ← is_nop ? '0 : pe_rs2
← 이후 VX_tcu_int FEDP에서 직접 사용
```

### Phase 8A — HW Flatten OT: micro-exp 원소별 flatten (논문 정석) ✅ 완료

#### 핵심 아키텍처 전환

**현재 구조 (Phase 7까지)**:
```
OT: exp_total = sa + sb − 254 만 계산 (packed scalar)
FEDP: MAC → (dot << exp_total) → sat → acc   [post-MAC scaling]
```

**Phase 8 목표 (논문 정석)**:
```
OT: A_flat[i] = sign_ext7(mantissa[i]) << micro_exp[i]  [pre-MAC element-wise]
FEDP: MAC → (dot << exp_total) → sat → acc              [block_exp 유지]
```

#### MX9 블록 구조 및 Vortex 파라미터 매핑

**MX9 블록 정의**:
```
한 블록 = 16 elements:
  ├── 1 × 8-bit E8M0 global_exp   (16개 원소 공유) → LDSCALE 1회
  ├── 8 × 1-bit micro_exp          (2개 원소마다 1비트, pair shared)
  └── 16 × 8-bit INT8 mantissa
```

**Vortex 파라미터와의 정합 (NT=4)**:
```
TILE_K = 4 words/thread × 4 INT8/word = 16 INT8 per thread (K-dim)
                                         ↑ 정확히 MX9 블록 크기 ✓

K_STEPS=2 × TC_K=2 × 4 bytes = 16 elements per warp-K = 1 global_exp ✓

FEDP 1회 호출: TC_K=2 words × 4 = 8 elements = 4 pairs → 4 micro_exp bits
32-bit word 1개: 4 elements = 2 pairs → 2 micro_exp bits
```

#### block_exp가 post-MAC 적용되는 수학적 근거

block_exp는 블록 내 **모든 원소가 동일한 값**을 공유하므로 MAC 밖으로 인수분해 가능:
```
dot = Σ (mantissa_A[i] × 2^sa) × (mantissa_B[i] × 2^sb)
    = Σ mantissa_A[i] × mantissa_B[i] × 2^(sa+sb)
    = dot_mantissa × 2^exp_total   ← post-MAC shift로 수학적 동등
```

반면 **micro_exp는 원소쌍마다 상이**하므로 인수분해 불가 → OT pre-MAC flatten 필수.

| 지수 유형 | 특성 | 처리 위치 |
|------|------|------|
| **micro_exp** (1-bit, per 2 elements) | 원소마다 다름 | **OT (pre-MAC)** — 필수 |
| **block_exp** (E8M0, shared) | 블록 전체 동일 | **FEDP (post-MAC)** — 수학적 동등 |

#### Phase 8A Tile Register 인코딩 결정

**설계 결정**: 32-bit word에 micro_exp를 별도 채널 없이 포함하기 위해 각 byte의 MSB를 micro_exp로 재정의.

```
Tile Register word 인코딩 (Phase 8A):
  byte = {micro_exp[1b], INT7_mantissa[7b]}

  word[31:24] = byte3: {micro_exp_pair1, m3[6:0]}
  word[23:16] = byte2: {micro_exp_pair1, m2[6:0]}  ← byte3와 동일 micro_exp
  word[15:8]  = byte1: {micro_exp_pair0, m1[6:0]}
  word[7:0]   = byte0: {micro_exp_pair0, m0[6:0]}  ← byte1와 동일 micro_exp

OT flatten: flat = sign_ext7(mantissa) << micro_exp
  mantissa: INT7 [-64, 63]
  micro_exp=0: flat = mantissa         → [-64, 63]  (INT8 범위 이내)
  micro_exp=1: flat = mantissa × 2     → [-128, 126] (INT8 범위 이내, saturate 불필요)
```

**호환성**: `micro_exp_mode=0` 플래그로 기존 INT8 passthrough 유지 → 기존 TC backward compatible.

#### Phase 8A 파이프라인 구조

**OT 위치 결정**: Phase 8A에서는 현재 위치(pe_switch 뒤 INT path) 유지.
FP path OT 지원은 FP WMMA에 scale context가 필요해지는 Phase 9+에서 검토.

```
[Phase 8A — 현재 위치 유지]
pe_switch → OT(1cy) → VX_tcu_int(5cy) = 6cy 총

OT 처리 (Phase 8A):
  1. scale_ctx → exp_total (E8M0, global, post-MAC용)    ← Phase 7 기존
  2. is_nop → rs1/rs2/rs3 zero-gate                     ← Phase 7 기존
  3. micro_exp_mode=1 + WMMA: per-pair flatten           ← Phase 8A 신규
     flat = sign_ext7(mantissa) << micro_exp
  4. micro_exp_mode=0 + WMMA: INT8 passthrough           ← backward compat
```

#### 구현 단계

**Phase 8A (주요 목표)**: micro-exp flatten HW화 (OT 위치 유지)

| 단계 | 파일 | 변경 내용 |
|------|------|-----------|
| 1 | `hw/rtl/VX_gpu_pkg.sv` | `tcu_args_t`에 `micro_exp_mode` 1-bit 추가 (padding -1) |
| 2 | `hw/rtl/tcu/VX_tcu_operand_transformer.sv` | `flatten_word()` function + `do_flatten` 분기 |
| 3 | `hw/rtl/tcu/tb_unit/tb_tcu_unit.sv` | Phase 8A TC 6개 추가 (micro_exp_mode=1) |
| 4 | `hw/rtl/tcu/tb_wmma/tb_tcu_wmma.sv` | Phase 8A TC 6개 추가 |
| 5 | `sim/simx/types.h` | `IntrTcuArgs.micro_exp_mode` 추가 |
| 6 | `sim/simx/tensor_unit.cpp` | `ag_wmma()` micro_exp flatten 에뮬레이션 |

변경 없는 파일: `VX_tcu_int.sv`, `VX_tcu_unit.sv`, `VX_tcu_fedp_int_scaled.sv`

**Phase 8B (완료)**: block_exp까지 OT에서 처리 (INT8 saturated, FEDP 변경 없음)
```
flat = sat8(sign_ext7(mantissa) << clamp(micro_exp + block_shift, -7, +7))
→ exp_total = 0 (FEDP plain MAC, post-MAC shift 없음)
→ FEDP/INT32 accumulator 변경 없음 (Option A)
```

Phase 8B 구현 파일:

| # | 파일 | 변경 내용 |
|---|------|-----------|
| 1 | `hw/rtl/VX_gpu_pkg.sv` | `block_flatten_mode` 1-bit 추가 (padding: -31 → -32) |
| 2 | `hw/rtl/tcu/VX_tcu_operand_transformer.sv` | `sat8_shift()`, `flatten_word_block()`, `do_block_flatten` 분기, `exp_total_ot=0` |
| 3 | `hw/rtl/tcu/tb_unit/tb_tcu_unit.sv` | Phase 8B TC 6개 추가 (block_flatten_mode=1) |
| 4 | `hw/rtl/tcu/tb_wmma/tb_tcu_wmma.sv` | Phase 8B TC 6개 (`TESTS_BFLAT` ifdef) |
| 5 | `sim/simx/types.h` | `IntrTcuArgs.block_flatten_mode` 추가 |
| 6 | `sim/simx/tensor_unit.cpp` | `extract_element()` block_flatten 분기, `ag_wmma()` sa/sb_actual |
| 7 | `sim/simx/tensor_unit.h` | `ag_wmma()` `block_flatten_mode` 파라미터 |
| 8 | `sim/simx/execute.cpp` | `ag_wmma()` 호출에 `block_flatten_mode` 전달 |

변경 없는 파일: `VX_tcu_int.sv`, `VX_tcu_unit.sv`, `VX_tcu_fedp_int_scaled.sv`

Phase 8B 핵심 파라미터:
- `OT_SHIFT_MAX = 7`: combined shift clamp 범위 [-7, +7]
- `sa_actual = scale_a - 127`, `sb_actual = scale_b - 127` (E8M0 actual exponent)
- `block_flatten_mode=1` 시 `exp_total_ot = 0` (FEDP no-shift)
- 우선순위: `do_block_flatten > do_flatten > passthrough`

Phase 8B TC 설계:
```
TC 이름              | sa   | sb   | A tile           | 검증 포인트
TC_block_neutral     | 127  | 127  | 0x01010101       | bsh=0, flat=1, d=8
TC_block_a1          | 128  | 127  | 0x01010101       | sa_bsh=+1, flat=2, d=16
TC_block_rshift      | 125  | 127  | 0x01010101       | sa_bsh=-2, shift=-2→flat=0, d=0
TC_block_combined    | 128  | 128  | 0x81818181 (m=1, mexp=1) | total_shift=2, flat=4, d=128
TC_block_sat         | 135  | 127  | 0x3F3F3F3F (m=63)| clamp+7, flat=127, d=1016
TC_block_neg_rshift  | 120  | 127  | 0x81818181       | sa_bsh=-7, total=-6, flat=0, d=0
```

#### Phase 8A TC 설계

```
TC 이름        | A micro_exp | B micro_exp | 검증 포인트
tc_mexp_all0   | 0 (전부)    | 0 (전부)    | flatten identity (INT7→INT8)
tc_mexp_a1_b0  | 1 (전부)    | 0 (전부)    | A ×2, B unchanged
tc_mexp_a0_b1  | 0 (전부)    | 1 (전부)    | B ×2, A unchanged
tc_mexp_mixed  | 교대 0/1    | 교대 1/0    | mixed pair micro_exp
tc_mexp_max    | 1, m=63     | 1, m=63     | flat=126, INT8 no-sat
tc_mexp_min    | 1, m=-64    | 1, m=-64    | flat=-128, INT8 min

pack_mx9_word helper (TB):
  byte = {micro_exp[1b], INT7_mantissa[7b]}
  word = {byte3, byte2, byte1, byte0}  (pair1={byte3,byte2}, pair0={byte1,byte0})
```

---

### Phase 9 — FP Path OT 확장: pe_switch 이전 OT 이동 + MX9→BF16 변환 ✅ 완료

#### 목표

OT를 pe_switch **이전**으로 이동하여 FP path(VX_tcu_fp)도 MX9 flatten 처리.
`mx9_to_bf16()` 변환을 OT에서 수행, VX_tcu_fp에 BF16 직접 공급.
LDSCALE hazard tracking을 FP / INT 양 path로 확장.

#### 현재 vs 목표 아키텍처

**현재 (Phase 8B)**:
```
pe_switch → pe_execute_if[1] → OT(1cy) → VX_tcu_int(5cy)
pe_switch → pe_execute_if[0] → VX_tcu_fp(Ncy)   ← OT 없음, MX9 미처리
```

**Phase 9 목표**:
```
per_block_execute_if
    → OT_v2(1cy)                          ← pe_switch 이전으로 이동
        ├─ is_fp=0 (fmt_s[3]=0, INT): INT8 flatten  기존 동작 유지
        └─ is_fp=1 (fmt_s[3]=1, FP):  mx9_to_bf16() 변환 (신규)
    → pe_switch
        ├─ pe=0 → VX_tcu_fp  (BF16 직접 수신, no further conversion)
        └─ pe=1 → VX_tcu_int (INT8 + exp_total, 기존과 동일)
```

#### FP Path 현황 (설계 기준)

| Backend | FP 포맷 | fmt_s_r (내부) | FEDP 레이턴시 |
|---------|---------|---------------|--------------|
| TCU_BHF | FP16, BF16 | 1, 2 | `(FMUL+FRND)+1+FRED+(FADD+FRND)` (N 의존) |
| TCU_DPI | FP16, BF16 | 1, 2 | 4cy (FMUL=2 + FACC=2) |
| TCU_DSP | FP16, BF16 | 1, 2 | `FCVT+FMUL+FRED+FADD` (~50+cy) |
| — | FP8 | 없음 | 3개 backend 모두 미구현 |

dispatch: `fmt_s[3]=1` → pe=0 (VX_tcu_fp). VX_tcu_fp 내부에서 `fmt_s[2:0]`만 FEDP로 전달.

#### mx9_to_bf16() 변환 알고리즘

```
입력: byte = {micro_exp[1b], INT7[7b]},  block_exp: E8M0 uint8 (bias=127)
출력: BF16 = {sign[1], exp8[8], mant7[7]}

실제 값: INT7 × 2^(micro_exp) × 2^(block_exp - 127)

1) sign      = m7[6]
2) mag7      = |INT7|  (7-bit two's complement 부호 반전, 범위: 1~64)
               sign=0: mag7 = m7[5:0]              (0x01..0x3F)
               sign=1: mag7 = (~m7 + 1) & 0x7F      (0x01..0x40)
               ※ INT7_MIN(-64): m7=0x40 → mag7=0x40  (6-bit 불가능, 7-bit 필수)
3) lz        = count_leading_zeros(mag7) over 7 bits [0..6]
4) bf16_exp  = block_exp + micro_exp + (6 - lz)
5) norm      = (mag7 << lz) & 0x7F   [bit6 = implicit leading 1]
   frac6     = norm[5:0]
   bf16_mant = {frac6[5:0], 1'b0}   → 7-bit (BF16 stored mantissa)

edge case:
  m7 == 0x00        → BF16 = 0x0000 (zero)
  bf16_exp ≤ 0      → flush to (signed) zero
  bf16_exp ≥ 0xFF   → clamp to 0xFE (max normal BF16)

packing (VX_tcu_fedp_bhf unpack 방식과 정합):
  rs_data[t] = {bf16_elem1[15:0], bf16_elem0[15:0]}  (2 elements per 32-bit word)
  (fedp: a_row16[2i] = a_row[i][15:0],  a_row16[2i+1] = a_row[i][31:16])
```

**FP path에서 exp_total 처리**: `mx9_to_bf16()`이 block_exp를 BF16 exponent에 embed →
VX_tcu_fedp_bhf/dpi/dsp는 exp_total 입력 없음. OT 출력 payload의 exp_total 필드는 FP path에서 don't care (0 설정).

**리스크**: priority encoder + 부호 처리 정확성 → **simx 구현 후 sweep 검증 필수**, RTL 구현은 그 이후.

simx 검증 항목:
```
m7=0x00, mexp=0, block=127 → BF16 = 0x0000  (zero)
m7=0x01, mexp=0, block=127 → BF16 = 0x3F80  (+1.0)
m7=0x7F, mexp=0, block=127 → BF16 = 0xBF80  (-1.0,  INT7: 1111111 = -1)
m7=0x01, mexp=1, block=127 → BF16 = 0x4000  (+2.0)
m7=0x3F, mexp=1, block=127 → BF16 = 0x42FC  (+126.0, m=63, ×2)
m7=0x40, mexp=1, block=127 → BF16 = 0xC300  (-128.0, INT7_MIN: mag7=0x40, lz=0, exp=134)
m7=0x01, mexp=0, block=128 → BF16 = 0x4000  (+2.0,   block_exp +1 shift)
```

#### 이중 Feedback 채널 (Hazard 확장)

**VX_tcu_fp에 추가할 output 포트** (VX_tcu_int Phase 7과 동일 패턴):
```systemverilog
`ifdef EXT_AG_TCU_ENABLE
output wire                    ot_fedp_enable,
output wire                    ot_result_fire,
output wire [NW_WIDTH-1:0]     ot_result_wid
`endif
```

**OT 내부 hazard 구조 변경**:
```
// 기존: wmma_inflight[NUM_WARPS] (INT 전용)
// 신규: 두 개로 분리

wmma_inflight_int[NUM_WARPS] ← int_result_fire, int_result_wid  (기존)
wmma_inflight_fp [NUM_WARPS] ← fp_result_fire,  fp_result_wid   (신규)

ldscale_hazard = is_nop_in
    && (wmma_inflight_int[execute_if_in.data.wid] != 0
     || wmma_inflight_fp [execute_if_in.data.wid] != 0)
```

Note: LDSCALE/LDTILE은 `pe_sel=1` 강제 (INT path) → FP delay pipe의 NOP 입력은 항상 0.
FP delay pipe는 `wmma_inflight_fp` 카운터 전용으로만 사용.

#### 이중 Delay Pipe

```systemverilog
// PIPE_LATENCY_FP: VX_tcu_fp 내부 FEDP_LATENCY + 1 (backend별 파라미터로 전달)
localparam DELAY_DEPTH_INT = PIPE_LATENCY_INT;  // = 5 (기존)
localparam DELAY_DEPTH_FP  = PIPE_LATENCY_FP;  // 신규, backend별 상이

reg [DELAY_DEPTH_INT-1:0] ldscale_delay_pipe_int;  // enable: int_fedp_enable
reg [DELAY_DEPTH_FP-1:0]  ldscale_delay_pipe_fp;   // enable: fp_fedp_enable
```

#### 파이프라인 레이턴시

```
INT path (변경 없음): OT(1cy) + VX_tcu_int(5cy) = 6cy
FP  path (신규):      OT(1cy) + VX_tcu_fp(FEDP_LATENCY_FP + 1cy)

TCU_UNIT_PIPE_LATENCY = max(INT path, FP path)  (scoreboard 기준)
```

#### 구현 단계

#### 구현 완료 파일

| # | 파일 | 변경 내용 |
|---|------|-----------|
| 1 | `hw/rtl/tcu/VX_tcu_fp.sv` | `ot_fedp_enable/ot_result_fire/ot_result_wid` output 추가 |
| 2 | `sim/simx/tensor_unit.cpp` | `mx9_to_bf16()` 구현 + sweep 검증 (1289/1289 PASS); `bf16_to_float()` 추가; `ag_wmma()` FP path 브랜치 |
| 3 | `hw/rtl/tcu/VX_tcu_operand_transformer.sv` | `is_fp = !fmt_s[3]`; `mx9_to_bf16_func()` RTL 함수; `mx9_word_to_bf16()`; 이중 wmma_inflight(INT/FP); PIPE_LATENCY_INT=5 |
| 4 | `hw/rtl/tcu/VX_tcu_unit.sv` | OT를 pe_switch 이전으로 재배치; PIPE_LATENCY_FP 로컬 계산; FP feedback 배선 |
| 5 | `hw/rtl/VX_gpu_pkg.sv` | `tcu_args_t`에 `mx9_fp_mode` 1-bit 추가 (padding: -32 → -33) |
| 6 | `sim/simx/types.h` | `IntrTcuArgs.mx9_fp_mode` 추가 |
| 7 | `sim/simx/execute.cpp` | `ag_wmma()` 호출에 `mx9_fp_mode` 전달 |
| 8 | `hw/rtl/tcu/tb_wmma/tb_tcu_wmma.sv` | `ref_mx9_to_bf16()`, `bf16_to_real()`, `fp32_to_real()`, `ref_d_fp()`, `run_wmma_fp()` 추가; `TESTS_FPFLAT` 6 TC |
| 9 | `hw/rtl/tcu/tb_wmma/Makefile` | `test-fpflat` / `test-fpflat-nt8` 타겟 추가 |

변경 없는 파일: `VX_tcu_int.sv`, `VX_tcu_fedp_int_scaled.sv`, `VX_tcu_fedp_bhf.sv`

#### fmt_s[3] 핵심 주의사항
```
fmt_s[3]=0 (FP: BF16_ID=2, FP16_ID=1) → pe_sel=0 → VX_tcu_fp → BHF BF16 MAC
fmt_s[3]=1 (INT: I8_ID=9, I32_ID=8)   → pe_sel=1 → VX_tcu_int → INT8 MAC
is_fp = !fmt_s[3]  (OT 내부에서 반드시 부정으로 판별)
```

#### Phase 9 TESTS_FPFLAT TC 구성
| TC | A byte | B byte | block_exp | 기대값 (K_STEPS=2) |
|----|--------|--------|-----------|-------------------|
| TC_fp_zero | 0x00 (BF16=0.0) | 0x01 (BF16=1.0) | 127 | d=0.0 |
| TC_fp_identity | 0x01 (BF16=1.0) | 0x01 | 127 | d=8.0 (4×K) |
| TC_fp_mexp1 | 0x81 (mexp=1→BF16=2.0) | 0x81 | 127 | d=32.0 |
| TC_fp_block_shift | 0x01→BF16=2.0 (block=128) | 0x01 | 128 | d=32.0 |
| TC_fp_neg | 0x7F (INT7=-1→BF16=-1.0) | 0x01 | 127 | d=-8.0 |
| TC_fp_nonzero_c | 0x01→1.0 | 0x01 | 127, C=4.0 | d=12.0 |

---

## 8. 테스트벤치 계층 및 검증 현황

| Level | DUT | 파일 | 결과 |
|-------|-----|------|------|
| 1 | VX_tcu_fedp_int_scaled | `tb/tb_fedp_int_scaled.sv` | **22/22 PASS** |
| 2 | VX_tcu_int (+operand_xformer) | `tb_int/tb_tcu_int.sv` | **10/10 PASS** |
| 3 | VX_tcu_uops | `tb_uops/tb_tcu_uops.sv` | **129/129 PASS** |
| 4 | VX_tcu_unit | `tb_unit/tb_tcu_unit.sv` | **26/26 PASS** (NT=4+8, Phase 8A/8B TC 포함) |
| 5 | VX_tcu_unit (K-acc) | `tb_wmma/tb_tcu_wmma.sv` | safe **9/9**, mexp **6/6**, bflat **6/6**, **fpflat 6/6** (NT=4+8) |
| 6 | VX_execute+VX_commit | `tb_execute/tb_execute.sv` | **10/10 PASS** |
| 7 | VX_issue+...+VX_commit | `tb_issue/tb_issue.sv` | **5/5 PASS** |
| 8 | VX_decode+...+VX_commit | `tb_decode/tb_decode.sv` | **7/7 PASS** |
| E2E | sgemm_ag_tcu kernel | simx driver | **PASSED** (exp=0, +2, -1) |

**모든 L1–L8 회귀 테스트 통과 (Phase 9 FP path MX9→BF16 포함)**

> **NT=8 Verilator 주의**: 각 Phase TC는 별도 ifdef로 분리. `make test-all-nt8` 순차 실행 필수 (동일 obj_dir 병렬 빌드 금지).
> Phase 8B: `TESTS_BFLAT` / `test-bflat-nt8`. Phase 9: `TESTS_FPFLAT` / `test-fpflat-nt8`.

### 테스트 패턴 (E8M0 기준)

```systemverilog
// fire_ldscale 호출 — K-loop 전에 1회
task fire_ldscale(input logic [7:0] scale_a, input logic [7:0] scale_b);
    pkt.rs1_data[0] = {16'b0, scale_b[7:0], scale_a[7:0]};
    pkt.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
    ...
endtask

// 중립 (exp_total=0):   fire_ldscale(8'd127, 8'd127)
// exp_total=+2:          fire_ldscale(8'd129, 8'd127)
// exp_total=+14 (old +7): fire_ldscale(8'd134, 8'd134)  → 134+134-254=14
// exp_total=-2:           fire_ldscale(8'd125, 8'd127)
```

---

## 9. simx ag_wmma() 구현 참조 (Phase 5 E8M0 기준)

```cpp
// sim/simx/tensor_unit.cpp — Phase 5 E8M0 완료
void TensorUnit::Impl::ag_wmma(
    uint32_t wid, uint32_t step_m, uint32_t step_n,
    const std::vector<reg_data_t>& rs1_data,
    const std::vector<reg_data_t>& rs2_data,
    const std::vector<reg_data_t>& rs3_data,
    std::vector<reg_data_t>& rd_data)
{
    // E8M0 Exponent Combine (signed 10-bit, [-254, +256])
    int32_t exp_total = (int32_t)scale_ctx_.scale_a[wid]
                      + (int32_t)scale_ctx_.scale_b[wid]
                      - 2 * (int32_t)AG_TCU_EXP_BIAS;  // AG_TCU_EXP_BIAS=127

    uint32_t b_off = (step_n % cfg::b_sub_blocks) * cfg::b_block_size;

    for (uint32_t i = 0; i < cfg::tcM; ++i) {
        for (uint32_t j = 0; j < cfg::tcN; ++j) {
            // Mantissa MAC (INT8 × INT8)
            int64_t dot = 0;
            for (uint32_t k = 0; k < cfg::tcK; ++k) {
                int32_t aw = rs1_data.at(i * cfg::tcK + k).i32;
                int32_t bw = rs2_data.at(b_off + j * cfg::tcK + k).i32;
                for (uint32_t b = 0; b < 4; ++b) {
                    dot += (int64_t)static_cast<int8_t>((aw >> (8*b)) & 0xFF)
                         * (int64_t)static_cast<int8_t>((bw >> (8*b)) & 0xFF);
                }
            }

            // Bidirectional Shift + Clamp (Phase 5 범위: exp ∈ [-254, +256])
            int64_t aligned;
            if (exp_total > AG_TCU_EXP_MAX) {         // AG_TCU_EXP_MAX = 30
                aligned = (dot >= 0) ? (int64_t)INT32_MAX : (int64_t)INT32_MIN;
            } else if (exp_total < 0) {
                int rshift = -exp_total;
                aligned = (rshift >= 63) ? (dot >= 0 ? 0LL : -1LL) : (dot >> rshift);
            } else {
                aligned = dot << exp_total;
            }

            // Saturation (1회)
            int32_t sat = (aligned > INT32_MAX) ? INT32_MAX :
                          (aligned < INT32_MIN) ? INT32_MIN :
                          static_cast<int32_t>(aligned);

            // Accumulator (wrapping 32-bit add)
            rd_data.at(i * cfg::tcN + j).i32 = sat + rs3_data.at(i * cfg::tcN + j).i32;
        }
    }
}
```

---

## 10. RTL 핵심 파일 참조

| 파일 | 위치 | 역할 | 상태 |
|------|------|------|------|
| `VX_tcu_pkg.sv` | `hw/rtl/tcu/` | TCU 파라미터 (`TCU_EXP_BITS=8`, `TCU_EXP_BIAS=127`, `TCU_EXP_TOTAL=10`) | ✅ |
| `VX_gpu_pkg.sv` | `hw/rtl/` | `tcu_op_e` 2-bit (WMMA/LDSCALE/LDTILE); `tcu_args_t` + `tile_type[1:0]` | ✅ |
| `VX_tcu_scale_ctx.sv` | `hw/rtl/tcu/` | Per-warp scale register file (8-bit E8M0 × 2) | ✅ |
| `VX_tcu_fedp_int_scaled.sv` | `hw/rtl/tcu/` | FEDP: MAC + 10-bit signed bidirectional shift + sat; `EXP_TOTAL=10` | ✅ |
| `VX_tcu_int.sv` | `hw/rtl/tcu/` | Phase 7: pure FEDP; feedback 포트 (`ot_fedp_enable/result_fire/result_wid`) | ✅ |
| `VX_tcu_operand_transformer.sv` | `hw/rtl/tcu/` | Phase 9: pe_switch 이전으로 이동; is_fp=!fmt_s[3]; mx9_to_bf16_func(); 이중 wmma_inflight(INT/FP); PIPE_LATENCY_INT=5 | ✅ |
| `VX_tcu_fp.sv` | `hw/rtl/tcu/` | FP FEDP wrapper (TCU_BHF/DPI/DSP); Phase 9: ot_fedp_enable/ot_result_fire/ot_result_wid output 추가 | ✅ |
| `VX_tcu_unit.sv` | `hw/rtl/tcu/` | Phase 9: OT를 pe_switch 이전으로 이동; PIPE_LATENCY_FP 로컬 계산; FP feedback 배선 | ✅ |
| `VX_uop_sequencer.sv` | `hw/rtl/core/` | LDSCALE/LDTILE uop 확장 제외 | ✅ |
| `VX_tcu_uops.sv` | `hw/rtl/tcu/` | uop 시퀀서: `tcu_op=WMMA` 전달 | ✅ |
| `VX_decode.sv` | `hw/rtl/core/` | WMMA, LDSCALE, LDTILE 디코딩 | ✅ |
