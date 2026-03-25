# AG-TCU Phase 10: MX9 INT Redesign + LDMICRO

## 1. 배경 및 동기

### 기존 구현의 문제점 (Phase 8A~9)

- **Element encoding**: `byte = {micro_exp[1b], INT7[7b]}`
  - element range: [-64, +63] → 논문의 INT8 full range [-128, +127] 미지원
  - micro_exp가 byte에 embedded → pair-shared 구조 미지원

- **INT path 출력**: INT32 (integer shift 방식)
  - 논문 Avant-Garde의 Scaling Unit 개념 미반영
  - C accumulation이 INT32 → FP32와의 혼용 불가

### Phase 10 목표

논문 Avant-Garde의 MX9 포맷을 정확하게 구현:

1. **Element = full INT8** (2's complement, 8-bit)
2. **micro_exp = pair-shared 1-bit**, LDMICRO 명령으로 별도 전달
3. **FEDP 출력 = FP32** (INT32 → FP32 변환 + global exp 적용 + FP32 accumulate)
4. **BF16 FP 경로 검증** TC 추가

---

## 2. MX9 포맷 구조 (논문 기준)

```
Element:           8-bit (INT8, 2's complement, range [-128, +127])
Level 2 scale:     1-bit micro_exp, pair-shared (2개 element 공유)
Level 1 scale:     8-bit shared_exp (E8M0, 블록당 공유) ← 기존 LDSCALE 유지

value = Element × 2^micro_exp × 2^(scale_a + scale_b - 254)
```

### 32-bit word 내 element packing

```
word = { INT8_3[7:0], INT8_2[7:0], INT8_1[7:0], INT8_0[7:0] }
pair0 = (INT8_0, INT8_1) → shared micro_exp_pair0
pair1 = (INT8_2, INT8_3) → shared micro_exp_pair1
```

byte[7]은 이제 sign bit (기존과 달리 micro_exp 아님).

---

## 3. 새로운 연산 흐름

```
[LDSCALE]  scale_ctx[wid] ← {scale_a, scale_b}      (기존 유지)
[LDMICRO]  micro_ctx[wid][thread][word] ← {pair1, pair0}  (신규)

[WMMA]
  OT (1cy):
    exp_total = scale_a + scale_b - 254               (기존 유지)
    for each word in rs1_data, rs2_data:
      pair0_mexp = micro_ctx_a[wid][t][k][0]
      pair1_mexp = micro_ctx_a[wid][t][k][1]
      flat_byte  = Saturate(INT8 << pair_mexp)        (신규: full INT8)

  FEDP (5cy, NT=4 / 6cy, NT=8):
    Stage 0-1 (MUL, 2cy): INT8 × INT8 → partial sums
    Stage 2   (RED, 1cy): reduction tree → INT32 dot product
    Stage 3   (SCALE, 1cy): INT32 → FP32 + exp_total 적용 [신규]
    Stage 4   (FADD, 1cy): FP32 + C(FP32) → FP32 output [신규]
```

### FEDP Latency 변경

| NT | LEVELS | 기존 | 신규 |
|----|--------|------|------|
| 4  | 1      | 4cy  | 5cy  |
| 8  | 2      | 5cy  | 6cy  |

`FEDP_LATENCY = MUL_LATENCY(2) + LEVELS + SCALE_LATENCY(1) + FADD_LATENCY(1)`

---

## 4. 신규 명령: LDMICRO

### ISA Encoding

| 필드 | 값 |
|------|-----|
| opcode | 7'h0B (TCU) |
| funct7 | TBD (기존 미사용 값 할당) |
| tcu_op | `TCU_OP_LDMICRO = 3'b011` |

### Payload Format

```
rs1_data[t] = A tile, thread t의 micro_exp:
  bits[2*BLOCK_CAP-1:0] = {pairs[BLOCK_CAP-1][1:0], ..., pairs[0][1:0]}
  각 pairs[k] = {micro_pair1[1b], micro_pair0[1b]}
  나머지 bits = don't care

rs2_data[t] = B tile, 동일 구조
```

NT=4 예시 (`BLOCK_CAP=4`):
```
rs1_data[t] = { 24'b0,
                pairs[3][1:0], pairs[2][1:0],
                pairs[1][1:0], pairs[0][1:0] }
```

### Hazard 정책

- LDMICRO도 LDSCALE과 동일하게 **wmma_inflight 체크** → 해당 warp의 INT WMMA 진행 중이면 stall
- WMMA 진행 중 micro_exp context가 바뀌면 결과 오염

---

## 5. 파일별 수정 계획

### 5.1 `VX_tcu_pkg.sv`

- `TCU_MX9_ID` comment 수정: 더 이상 FP path 아님, INT path + LDMICRO 방식으로 변경

### 5.2 `VX_gpu_pkg.sv`

- `tcu_op_e` 2-bit → 3-bit 확장:
  ```systemverilog
  typedef enum logic [2:0] {
      TCU_OP_WMMA    = 3'b000,
      TCU_OP_LDSCALE = 3'b001,
      TCU_OP_LDTILE  = 3'b010,
      TCU_OP_LDMICRO = 3'b011
  } tcu_op_e;
  ```
- `tcu_args_t` padding 1-bit 감소 (tcu_op 1-bit 증가 반영)

### 5.3 `VX_tcu_micro_ctx.sv` (신규)

`VX_tcu_scale_ctx`와 유사한 구조:

```systemverilog
module VX_tcu_micro_ctx #(
    parameter NUM_WARPS = `NUM_WARPS
) (
    input  wire clk, reset,
    // Write: LDMICRO fire
    input  wire                        wr_valid,
    input  wire [NW_WIDTH-1:0]         wr_wid,
    input  wire [`NUM_THREADS-1:0][`XLEN-1:0] wr_data_a,  // rs1_data
    input  wire [`NUM_THREADS-1:0][`XLEN-1:0] wr_data_b,  // rs2_data
    // Read: combinational, by wid
    input  wire [NW_WIDTH-1:0]         rd_wid,
    output wire [`NUM_THREADS-1:0][TCU_BLOCK_CAP-1:0][1:0] rd_micro_a,
    output wire [`NUM_THREADS-1:0][TCU_BLOCK_CAP-1:0][1:0] rd_micro_b
);
```

저장 구조: `reg [1:0] micro_a_r [NUM_WARPS][NUM_THREADS][BLOCK_CAP]`

### 5.4 `VX_tcu_operand_transformer.sv`

- `VX_tcu_micro_ctx` 인스턴스 추가
- `is_ldmicro_in` decode 추가 (`tcu_op == TCU_OP_LDMICRO`)
- `is_nop_in`: LDSCALE, LDTILE, **LDMICRO** 모두 포함
- flatten 함수 교체:
  ```systemverilog
  // 기존 (제거)
  // flatten_mx9_byte: byte[7]=micro_exp, byte[6:0]=INT7
  // flatten_mx9_word

  // 신규
  function automatic logic [7:0] flatten_int8_byte(
      input logic [7:0] byte_in,
      input logic       micro_exp
  );
      logic signed [8:0] wide;
      wide = {byte_in[7], byte_in} <<< {8'b0, micro_exp};
      if      (wide > 9'sd127)  return 8'h7F;
      else if (wide < -9'sd128) return 8'h80;
      else                      return wide[7:0];
  endfunction

  function automatic logic [31:0] flatten_int8_word(
      input logic [31:0] word,
      input logic [1:0]  micro_pairs  // {pair1, pair0}
  );
      logic [31:0] res;
      res[ 7: 0] = flatten_int8_byte(word[ 7: 0], micro_pairs[0]);
      res[15: 8] = flatten_int8_byte(word[15: 8], micro_pairs[0]);
      res[23:16] = flatten_int8_byte(word[23:16], micro_pairs[1]);
      res[31:24] = flatten_int8_byte(word[31:24], micro_pairs[1]);
      return res;
  endfunction
  ```
- WMMA 처리 시 micro_ctx에서 pair별 micro_exp 읽어 flatten:
  ```systemverilog
  // do_flatten_mx9 조건 동일 유지 (fmt_s[3]=1, WMMA)
  ot_data_next.rs1_data[t] = flatten_int8_word(
      execute_if_in.data.rs1_data[t],
      rd_micro_a[t][word_k]);  // word_k = a_off + ii*TC_K + kk
  ```
- `do_mx9_to_bf16` 경로 **제거** (MX9 FP 경로 삭제)
- `do_block_flatten`, `do_flatten` (Phase 8A/8B 코드) **제거**
- `mx9_to_bf16_func`, `mx9_word_to_bf16` 함수 **제거**

### 5.5 `VX_tcu_fedp_int_scaled.sv`

기존 Partial Sum Alignment (barrel shift + INT32 sat) 단계 교체:

**Stage 3 — SCALE (신규, 1cy):**
```
INT32 dot → FP32 변환 (조합 회로):
  sign    = dot[31]
  abs_dot = sign ? -dot : dot
  clz_pos = CLZ(abs_dot)              // 32-bit CLZ
  exp_f32 = 31 - clz_pos + 127       // biased exponent
  mant    = abs_dot << (clz_pos+1)   // leading 1 제거, 23-bit mantissa
  fp32    = {sign, exp_f32[7:0], mant[30:8]}

exp_total 적용 (조합 회로):
  new_exp = fp32[30:23] + exp_total (saturating)
  → 0(denorm)/Inf/NaN 특수값 처리 (BHF와 동일)

결과를 pipe register로 1cy 지연
```

**Stage 4 — FADD (신규, 1cy):**
```
FP32 scaled + C(FP32) → FP32
단순 1-cycle FP32 adder (정밀도: INT8 MAC 결과에 충분)
```

**Latency 파라미터 업데이트:**
```systemverilog
localparam SCALE_LATENCY = 1;
localparam FADD_LATENCY  = 1;
localparam ACC_LATENCY   = RED_LATENCY + SCALE_LATENCY + FADD_LATENCY;
// NT=4: ACC_LATENCY = 1 + 1 + 1 = 3, FEDP_LATENCY = 2 + 3 = 5
// NT=8: ACC_LATENCY = 2 + 1 + 1 = 4, FEDP_LATENCY = 2 + 4 = 6
```

### 5.6 `sim/simx/types.h`

- `tcu_op` 관련 enum에 `TCU_OP_LDMICRO` 추가

### 5.7 `sim/simx/tensor_unit.cpp`

- `micro_exp_ctx[NUM_WARPS][NUM_THREADS][BLOCK_CAP]` per-warp context 추가
- LDMICRO 처리: `micro_exp_ctx[wid][t][k]` 기록
- `ag_wmma()` INT path 수정:
  - element 추출: `int8_t elem = (int8_t)(word >> (8*byte_idx))`
  - flatten: `int8_t flat = sat8(elem << micro_exp_ctx[wid][t][word_k][pair_idx])`
  - dot product: `int32_t dot = Σ (flat_a × flat_b)`
  - FP32 변환: `float dot_f = (float)dot`
  - exp_total 적용: FP32 exponent 조정 (Phase 9 BHF와 동일 방식)
  - result: `rv_fadd_s(dot_fp32_bits, c_fp32_bits, frm, fflags)`
- 기존 `mx9_to_bf16`, `bf16_to_float` MX9 FP 경로 코드 제거

### 5.8 `tb_wmma/tb_tcu_wmma.sv`

- `fire_ldmicro()` task 추가:
  ```systemverilog
  task automatic fire_ldmicro(
      input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] micro_a,
      input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] micro_b
  );
  ```
- `ref_d_int()` → `ref_d_mx9_int()` (FP32 reference):
  ```
  dot = Σ Saturate(INT8_a << mexp_a) × Saturate(INT8_b << mexp_b)
  dot_f = float(dot)
  dot_scaled = dot_f × 2^exp_total
  result = dot_scaled + fp32(C)
  ```
- `run_wmma()` 비교를 FP32로 전환 (`got_r`, `exp_r` real 비교)
- MX9 FP 관련 TC 및 함수 제거 (`TC_mx9_fp_*`, `run_wmma_fp`, `ref_mx9_to_bf16`)
- BF16 FP 경로 TC 추가 (`run_wmma_bf16`, `build_dispatch_bf16`):
  ```
  TC_bf16_exp0   — BF16 입력, exp_total=0
  TC_bf16_exp_pos — exp_total=+1
  TC_bf16_exp_neg — exp_total=-1
  TC_bf16_neg    — 음수 BF16 입력
  ```

### 5.9 `tb_unit/tb_tcu_unit.sv`

- `fire_ldmicro()` task 추가
- INT path TC 예상값 FP32로 변경
- saturation 경계값 TC 추가: `{mexp=1, byte=0x7F}` → sat(+127 capped), `{mexp=1, byte=0x80}` → sat(-128)

---

## 6. 제거되는 코드

| 항목 | 위치 | 이유 |
|------|------|------|
| `do_mx9_to_bf16` | OT | MX9 FP 경로 제거 |
| `mx9_to_bf16_func`, `mx9_word_to_bf16` | OT | 동상 |
| `do_block_flatten`, `flatten_word_block` | OT | Phase 8B 코드 제거 |
| `do_flatten`, `flatten_mx9_word` | OT | Phase 8A 방식 교체 |
| `mx9_fp_mode` | `VX_gpu_pkg.sv` | Phase 9 FP MX9 모드 불필요 |
| `block_flatten_mode` | `VX_gpu_pkg.sv` | Phase 8B 모드 불필요 |
| `micro_exp_mode` | `VX_gpu_pkg.sv` | Phase 8A 모드 불필요 |
| `TC_mx9_fp_*`, `run_wmma_fp` | tb_wmma | MX9 FP TC 제거 |
| `VX_tcu_fedp_bhf.sv` MX9 path | — | MX9는 INT path만 사용 |

---

## 7. 유지되는 코드

| 항목 | 이유 |
|------|------|
| `VX_tcu_scale_ctx` | LDSCALE/exp_total 경로 기존 유지 |
| `VX_tcu_fedp_bhf` | BF16/FP16 FP 경로 유지 |
| `VX_tcu_fp` | FP 경로 유지 |
| `wmma_inflight` counter | LDSCALE/LDMICRO hazard 공용 |
| `exp_total` payload | OT → FEDP 전달 방식 유지 |

---

## 8. 검증 계획

### L2: tb_tcu_int (OT 없음, 직접 FEDP 테스트)

| TC | 내용 | 검증 포인트 |
|----|------|------------|
| TC_fp32_basic | INT8 MAC → FP32 출력 | 기본 동작 |
| TC_fp32_exp_pos | exp_total=+2 | Scaling Unit 양수 |
| TC_fp32_exp_neg | exp_total=-1 | Scaling Unit 음수 |
| TC_fp32_sat | dot=INT32_MAX | FP32 변환 큰 값 |

### L4: tb_tcu_unit (OT 포함)

| TC | 내용 | 검증 포인트 |
|----|------|------------|
| TC_ldmicro_0 | micro_exp=0 전부 | INT8 passthrough |
| TC_ldmicro_1 | micro_exp=1 전부 | ×2 flatten |
| TC_ldmicro_sat | byte=0x7F, mexp=1 | saturation +127 |
| TC_ldmicro_sat_neg | byte=0x80, mexp=1 | saturation -128 |
| TC_ldmicro_mixed | pair별 0/1 혼합 | pair-shared 동작 |
| TC_hazard | LDMICRO hazard | stall 정확성 |

### L5: tb_wmma

| TC 그룹 | 내용 |
|---------|------|
| `TESTS_SAFE` | INT path K-accumulation regression (기존) |
| `TESTS_MX9_INT` | LDMICRO + INT8 flatten + FP32 출력 |
| `TESTS_BF16_FP` | 일반 BF16 FP 경로 검증 (신규) |

---

## 9. 구현 순서

```
1. VX_gpu_pkg.sv         — tcu_op_e 3-bit, padding 수정
2. VX_tcu_micro_ctx.sv   — 신규 모듈
3. VX_tcu_operand_transformer.sv — flatten 교체, LDMICRO 추가
4. VX_tcu_fedp_int_scaled.sv    — Scaling Unit + FP32 출력
5. sim/simx/types.h + tensor_unit.cpp — simx 동기화
6. tb_unit/tb_tcu_unit.sv — L4 TC 수정
7. tb_wmma/tb_tcu_wmma.sv — L5 TC 수정 + BF16 추가
8. 전체 검증 (L2→L4→L5 순)
```

---

## 10. 파이프라인 단계별 검증 전략 (Phase 10)

### 단계 계층

```
tb_decode  (L8) — VX_decode + VX_issue + VX_execute + VX_commit
tb_issue   (L7) — VX_issue + VX_execute + VX_commit
tb_execute (L6) — VX_execute + VX_commit
tb_pipeline(L9) — VX_fetch + VX_decode + ... (raw instruction → output)
```

### Phase 10 핵심 영향 요약

| 단계 | Phase 10 변경 사항 |
|------|--------------------|
| decode | fmt_d: `TCU_I32_ID→TCU_FP32_ID`; LDMICRO 신규 디코딩 (tcu_op=3'b011, wb=0) |
| issue/uop_seq | LDMICRO 단일 UOP (미확장); wb=0 → commit_wb.valid 미발생 |
| execute | INT FEDP 출력: INT32 → FP32 (int32_to_fp32 + fp32_exp_scale + fp32_add) |
| commit | 변경 없음 (FP32 비트 그대로 전달) |
| fetch / schedule | 변경 없음 |

### 단계별 검증 초점

**tb_decode (L8)**:
- WMMA decode: `ex_type=EX_TCU`, `tcu_op=WMMA`, `fmt_d=TCU_FP32_ID`, `fmt_s=TCU_I8_ID`, `used_rs=111`
- LDSCALE decode: `tcu_op=LDSCALE`, `used_rs=001` (rs1 only), `wb=1`
- LDMICRO decode(신규): `tcu_op=LDMICRO`, `used_rs=011` (rs1+rs2), `wb=0`
- UOP 확장 수: WMMA→UOPS개, LDSCALE→1개, LDMICRO→1개 (no-commit)

**tb_issue (L7)**:
- LDSCALE 단일 UOP (RTL fix 검증 — uop_sequencer 미확장)
- WMMA UOP 수 확인 (TCU_UOPS commits, A=B=C=0 → 0x0 출력)
- LDMICRO 단일 UOP + wb=0 → commit 없음 (20 cycle 대기 후 valid=0 확인)
- FP32 K-accumulation: C=0, A=B=ones, exp=2 → k0=`0x42000000`, kfinal=`0x42800000`

**tb_execute (L6)**:
- INT8 WMMA → FP32 출력 (ref_d_fp32 shortreal 레퍼런스 모델 사용)
- 양/음 exp 스케일, 음수 C 누산 (FP32 형식)
- ALU ADD 독립 검증 (format-agnostic)
- TCU + ALU 동시 실행 + VX_commit 우선순위 중재

### FP32 기대값 변환표

| 연산 조건 | INT32 (Phase 9 이전) | FP32 (Phase 10) |
|-----------|---------------------|-----------------|
| dot=8,  exp=0  | 8    | `0x41000000` (8.0f)    |
| dot=8,  exp=2  | 32   | `0x42000000` (32.0f)   |
| dot=8,  exp=4  | 128  | `0x43000000` (128.0f)  |
| dot=8,  exp=-2 | 2    | `0x40000000` (2.0f)    |
| dot=20, exp=6  | 1280 | `0x44A00000` (1280.0f) |
| A=B=0, C=0    | 0    | `0x00000000` (0.0f)    |
| k0 (ones, exp=2, C=0) | 32 | `0x42000000` |
| kfinal (k1 누산)       | 64 | `0x42800000` |
| C=-200.0f, dot=8, exp=0 | N/A | C=`0xC3480000`, out=`0xC3400000` |

### 핵심 RTL 변경 (Phase 10, 하위 TB 영향)

| RTL 변경 | 영향 TB | 수정 방향 |
|---------|---------|-----------|
| `tcu_op_e` 2→3 bit, LDMICRO=3'b011 추가 | decode, issue | `encode_ldmicro()` 추가, decode 필드 검증 |
| WMMA fmt_d: I32→FP32 | 모든 TB | `TCU_I32_ID` → `TCU_FP32_ID` |
| INT FEDP 출력: INT32→FP32 | execute, issue | 기대값 FP32 비트 패턴으로 교체 |
| uop_seq: LDMICRO 미확장 (단일 UOP) | decode, issue | LDMICRO 후 commit 없음 검증 |

### TB 수정 범위 요약

| TB | 추가 TC | 수정 TC | 삭제 TC |
|----|---------|---------|---------|
| tb_decode | TC5_ldmicro_fields | TC1(fmt_d), TC4(fmt_d) | TC6, TC7 |
| tb_issue | TC3_ldmicro_single_uop | TC2(fmt_d), TC4(FP32값), TC5(FP32값) | TC3(passthrough/INT32) |
| tb_execute | — | TC1~TC5(ref_d_fp32), TC8~TC9 | TC2(pos_sat/Phase8A) |
| tb_pipeline | — | — | — (이미 Phase 10 검증 완료) |
