# AG-TCU Operand Transformer 확장 계획
## OT Extension Plan: 범용 Numeric Format 지원

---

## 1. 목적

현재 AG-TCU Operand Transformer (OT)는 아래 포맷만 지원한다.

| 포맷 | OT 처리 | FEDP |
|------|---------|------|
| FP32 / FP16 / BF16 | passthrough | VX_tcu_fp (BHF) |
| MX9 (INT8 + 1-bit pair-shared micro_exp) | micro_exp 흡수 → INT8, fmt_s 패치 | VX_tcu_int |
| MXINT8 / I8 | micro_exp passthrough (=0) | VX_tcu_int |

OCP Microscaling (MX) 표준 포맷인 MXFP8 E4M3 / E5M2를 비롯하여
향후 FP6 / FP4까지 범용적으로 지원할 수 있도록 아키텍처를 확장한다.
또한 논문의 preprocessing 철학에 맞게 OT flattening을 WMMA dispatch마다 반복하지 않도록
FLAT 명령어를 도입한다.

---

## 2. 아키텍처 원칙: OT와 FEDP의 책임 분리

### OT의 역할 (논문 정의)

> OT는 execute 단계 앞에서 **multi-level scaling format을 single-level scaling format으로
> flattening**하는 하드웨어이다. 단, 1st-level (global/block scale)은 제외한다.

```
Input:  element + [2nd-level factor] + [3rd-level factor] + ...
           ↓ OT
Output: flattened element  (1st-level scale만 남음)
```

**핵심 원칙**: OT 출력 element의 numeric format = flattening 전 element의 numeric format

```
MX9  예시: INT8(raw) + micro_exp(1-bit)  →OT→  INT8(flat)   [포맷: INT8 유지]
MXFP8예시: FP8 element + block_exp(1st) →OT→  FP8(그대로)  [2nd-level 없음, passthrough]
```

MX9의 경우 micro_exp를 흡수하면 element가 "순수 INT8"이 되므로 fmt_s를 I8_ID로 패치하는 것이 맞다.
FP8의 경우 흡수할 2nd-level factor가 없으므로 OT는 **passthrough**, fmt_s 패치 없음.

### OT / FEDP 책임 분리표

| 단계 | 담당 | 내용 |
|------|------|------|
| **OT** | multi-level flattening | 2nd-level 이상을 element에 흡수 (FLAT 시점에 1회) |
| **FEDP front-end** | 입력 포맷 정규화 | FP8 → BF16 변환 (compute unit 자신의 입력 처리) |
| **FEDP compute** | MAC 연산 | BF16 × BF16 (FP path), INT8 × INT8 (INT path) |
| **FEDP post-scale** | 1st-level scale 적용 | × 2^exp_total |

### 논문 vs 현재 구현 (Late Binding 문제)

```
현재 Phase 10 (Late Binding):
  LDTILE → LDMICRO → WMMA (OT × N_UOPS마다 flatten) → commit (C tile FP32)
  → 같은 tile data를 N_UOPS번 flatten (중복 연산)

논문 (Early Binding, Phase B 목표):
  LDTILE → LDMICRO → FLAT (OT × 1회, A/B tile write-back) → WMMA (OT bypass)
  → flatten once, reuse many times
```

> **논문의 contiguous packing 방식(element + scale inline)은 Vortex에 적용 불가.**
> 논문은 128-byte(1024-bit) 워프 레지스터를 전제하여 전체 블록을 한 번에 fetch하지만,
> Vortex는 32-bit XLEN이므로 block-level contiguous 구조를 하드웨어로 직접 파싱할 수 없다.
> 따라서 micro_exp는 별도 LDMICRO + micro_ctx(indexed context)로 유지한다.

---

## 3. fmt_s 인코딩

현재 4-bit `fmt_s` 라우팅 규칙:

```
bit[3]=0  →  pe_sel=0  →  VX_tcu_fp  (FP path)
bit[3]=1  →  pe_sel=1  →  VX_tcu_int (INT path)
```

### 현재 할당

| ID | fmt_s[3:0] | 포맷 | 경로 |
|----|-----------|------|------|
| 0 | 0000 | FP32 | FP |
| 1 | 0001 | FP16 | FP |
| 2 | 0010 | BF16 | FP |
| 4 | 0100 | MX9  | FP → OT가 INT8으로 flatten → INT (fmt_s 패치) |
| 8 | 1000 | I32  | INT |
| 9 | 1001 | I8   | INT |

### 신규 할당 (Phase D)

| ID | fmt_s[3:0] | 포맷 | 경로 |
|----|-----------|------|------|
| 5 | 0101 | **FP8 E4M3** | FP (bit[3]=0, OT passthrough, FEDP front-end 변환) |
| 6 | 0110 | **FP8 E5M2** | FP (bit[3]=0, OT passthrough, FEDP front-end 변환) |

**pe_switch 변경 없음**: FP8 IDs가 bit[3]=0 공간에 있으므로 자동으로 FP path로 라우팅.
OT는 fmt_s를 패치하지 않음.

### 예약 (Phase E)

| ID | fmt_s[3:0] | 포맷 | 경로 |
|----|-----------|------|------|
| 3 | 0011 | FP6 E2M3 | FP (OT passthrough, FEDP front-end 변환) |
| 7 | 0111 | FP6 E3M2 | FP (OT passthrough, FEDP front-end 변환) |
| TBD | — | FP4 E2M1 | Phase D에서 결정 |

> **Phase D 전 검토 필요**: FP6/FP4까지 추가되면 fmt_s 4-bit 공간이 포화될 수 있다.
> Phase D 착수 전 `{bit[3]: path, bit[2:1]: class, bit[0]: subtype}` 구조로 재정의 검토.

---

## 4. Phase A: micro_exp N-bit 파라미터화 ✅ 완료

### 4.1 배경

현재 `flatten_int8_byte`의 mexp는 1-bit 고정이다.
표준 포맷 중 micro_exp > 1-bit인 것은 현재 없으나,
향후 커스텀 포맷 대응을 위해 아키텍처를 N-bit으로 파라미터화한다.

**기본값 `MEXP_BITS=1`**: Phase 10 RTL과 bit-identical.

### 4.2 micro_exp 의미 (명시)

> **micro_exp는 선형 exponent shift로 해석된다: `value = int8 × 2^mexp`**
>
> MEXP_BITS=1: shift 0 또는 1 (×1, ×2)
> MEXP_BITS=N: shift 0 ~ 2^N−1

log-scale 또는 asymmetric scaling은 이 구조로 표현 불가능하다.

### 4.3 micro_ctx 구조화 (structure encode)

micro_ctx를 N-bit으로 키우는 것에 그치지 않고, 내부를 structured field로 설계한다.
SW가 여러 level의 scaling factor를 pre-sum하지 않고, HW가 field별로 읽어 덧셈 합산한다.

```systemverilog
// micro_ctx 내부 구조 예시 (확장 시)
typedef struct packed {
    logic [EXTRA_BITS-1:0] extra_exp;  // 추후 level 추가 시
    logic [SUB_BITS-1:0]   sub_exp;    // 추후 level 추가 시
    logic [MICRO_BITS-1:0] micro_exp;  // 현재 (MICRO_BITS=1)
} micro_ctx_field_t;

// OT 내부: 덧셈으로 합산 (concatenation 아님)
wire [MEXP_BITS-1:0] total_shift =
    MEXP_BITS'(rd_mexp.extra_exp)
  + MEXP_BITS'(rd_mexp.sub_exp)
  + MEXP_BITS'(rd_mexp.micro_exp);
```

**핵심**: granularity가 다른 level이 추가되어도 ctx register 개수 고정 (scale_ctx + micro_ctx 2개).

**total_shift 산출은 반드시 덧셈(+), concatenation({}) 사용 금지.**
`{sub_exp, mexp}` = `sub_exp × 2^MICRO_BITS + mexp` ≠ `sub_exp + mexp`

### 4.4 변경 사항

#### VX_tcu_micro_ctx.sv

```systemverilog
module VX_tcu_micro_ctx #(
    parameter NUM_WARPS = 4,
    parameter MEXP_BITS = 1   // 기본값 1 → 현행과 동일
) ( ... );
    // 저장소 타입: [2*MEXP_BITS-1:0] per thread (pair0 + pair1)
```

#### VX_tcu_operand_transformer.sv

```systemverilog
module VX_tcu_operand_transformer #(
    parameter PIPE_LATENCY_INT = 6,
    parameter MEXP_BITS = 1
) ( ... );

// flatten_int8_byte: N-bit saturating left shift
function automatic logic [7:0] flatten_int8_byte(
    input logic [7:0]           int8_in,
    input logic [MEXP_BITS-1:0] mexp
);
    // wide = sign_extend(int8_in, FLAT_W), shifted = wide << mexp
    // overflow = shifted[FLAT_W-1:7] not all-same → saturate by original sign
```

#### LDMICRO payload

```
MEXP_BITS=1 (현행):
  rs1_data[t][1:0] = {pair1_mexp_a[0], pair0_mexp_a[0]}

MEXP_BITS=N (확장, structure encode):
  rs1_data[t][2N-1:0] = {pair1_total_shift[N-1:0], pair0_total_shift[N-1:0]}
  (각 field는 SW가 level별로 채워 넣음, HW가 합산)
```

### 4.5 수정 파일 목록

| 파일 | 변경 내용 |
|------|-----------|
| `VX_tcu_micro_ctx.sv` | `MEXP_BITS` 파라미터; 저장소/포트 타입 변경 |
| `VX_tcu_operand_transformer.sv` | `MEXP_BITS` 파라미터; `flatten_int8_byte` N-bit 일반화 |
| `VX_tcu_unit.sv` | `MEXP_BITS`를 OT에 전달 |

---

## 5. Phase B: FLAT 명령어 (논문 구조 정합) ✅ 완료

### 5.1 목적

논문의 "피연산자 평탄화는 전처리 단계에서 1회" 원칙을 하드웨어로 구현한다.

```
LDTILE  → tile registers (plain INT8)
LDMICRO → micro_ctx[wid][t]
FLAT    → tile registers 읽기 + micro_ctx 참조 + OT 1회 → tile registers write-back
WMMA    → OT bypass, flattened tile registers → FEDP 직접
```

FLAT을 한 번 실행한 뒤 WMMA를 여러 번 반복해도 OT는 다시 실행되지 않는다.
LDMICRO / micro_ctx는 Phase 10 구조 그대로 유지한다.

### 5.2 FLAT 명령어 정의

```
ISA:      tcu_op = TCU_OP_FLAT (신규; tcu_op_e 확장)
입력:     A/B tile registers (plain INT8) + micro_ctx[wid][t] (mexp)
동작:     micro_ctx 읽기 → flatten_int8_word(tile_reg, mexp) → write-back
UOP 확장: NRA UOPs (A tile) + NRB UOPs (B tile)
          각 UOP: rs1 = tile_reg_i, rd = tile_reg_i, wb = 1
```

### 5.3 실행 경로 (FLAT short commit path)

FLAT은 FEDP를 거치지 않는다. OT 출력을 직접 commit으로 연결하는 short path가 필요하다.

```
dispatch → OT (micro_ctx 참조 → flatten, 1cy) → [short commit path — FEDP bypass]
                                                    ↓
                                                result_t {
                                                  rd   = tile_reg_i,
                                                  data = flattened INT8 (4×INT8 packed),
                                                  wb   = 1
                                                }
                                                    ↓
                                                VX_commit → register file write-back
```

`result_t.data`는 범용 XLEN-bit 필드이므로 flattened INT8을 A/B tile 레지스터에
쓰는 것이 구조적으로 가능하다 (commit path에 FP32 전용 제약 없음).

### 5.4 OT 변경사항

**FLAT 분기 (신규)**:

```systemverilog
wire is_flat_in = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_FLAT);

// FLAT: 기존 flatten_int8_word 재사용 (micro_ctx rd_mexp_a/b 그대로 참조)
if (is_flat_in) begin
    for (integer t = 0; t < `NUM_THREADS; t++) begin
        ot_data_next.rs1_data[t] = flatten_int8_word(rs1_data[t], rd_mexp_a[t]);
        ot_data_next.rs2_data[t] = flatten_int8_word(rs2_data[t], rd_mexp_b[t]);
    end
    ot_data_next.op_args.tcu.fmt_s = 4'(TCU_I8_ID);  // WMMA 후 I8_ID로 발행 → bypass
end
```

`is_nop_in`에 `TCU_OP_FLAT` 추가 (FLAT은 short commit path 사용 → FEDP zero-gate).

### 5.5 WMMA after FLAT

```systemverilog
// SW convention:
// FLAT 전 WMMA:  fmt_s = TCU_MX9_ID → OT do_flatten_mx9 (Phase 10 방식)
// FLAT 후 WMMA:  fmt_s = TCU_I8_ID  → OT passthrough (tile reg에 이미 pure INT8)
// HW 상태 비트 방식 불사용 (SW convention으로 단순화)
```

### 5.6 program order 제약 변화

```
Phase 10: LDTILE → LDMICRO → WMMA
Phase B:  LDTILE → LDMICRO → FLAT → WMMA

FLAT 후 LDMICRO 재실행: micro_ctx 갱신 → tile reg stale → re-FLAT 필요 (SW 관리)
FLAT 후 LDTILE  재실행: tile reg 갱신 → re-FLAT 필요 (SW 관리)
```

### 5.7 수정 파일 목록

| 파일 | 변경 내용 |
|------|-----------|
| `VX_tcu_pkg.sv` | `TCU_OP_FLAT` 추가; tcu_op_e 확장 |
| `VX_tcu_uops.sv` | FLAT UOP 시퀀싱 (NRA + NRB sequential) |
| `VX_tcu_unit.sv` | FLAT short commit path (OT 출력 → commit, FEDP bypass) |
| `VX_tcu_operand_transformer.sv` | `is_flat_in` 분기 신규; `is_nop_in`에 FLAT 포함 |
| simx | `ldflat()` 구현 (tile register에 flattened 값 write) |
| TB | LDMICRO → FLAT → WMMA 시퀀스; FLAT TC 추가 |

---

## 6. Phase C: META_BITS / LOG2_GROUP_SIZE 파라미터화 ✅ 완료

### 6.1 목적

Phase A에서 `MEXP_BITS`로 pair당 비트 폭을 파라미터화했지만, GROUP_SIZE(공유 단위)는
pair=2로 하드와이어 고정되어 있다.
이 Phase에서 두 가지를 완성한다.

1. `MEXP_BITS` → `META_BITS` 이름 정리 (의미 명확화: 포맷-비의존 메타데이터 폭)
2. `LOG2_GROUP_SIZE` 파라미터 추가 (공유 단위 파라미터화)
3. `flatten_int8_word` 내 2D packed array 캐스팅으로 가독성 및 합성 안정성 확보
4. `decode_meta()` placeholder 함수 추가 (미래 3-level 포맷 대응 진입점)

**기본값 유지**: `META_BITS=1`, `LOG2_GROUP_SIZE=1` → Phase B RTL과 bit-identical.

---

### 6.2 파라미터 정의

| 파라미터 | 기본값 | 의미 |
|----------|--------|------|
| `META_BITS` | 1 | ctx 엔트리당 비트 수 (포맷-비의존) |
| `LOG2_GROUP_SIZE` | 1 | 몇 개의 byte가 하나의 ctx 엔트리를 공유 (GROUP_SIZE = 2^LOG2_GROUP_SIZE) |

파생 상수 (OT / micro_ctx 내부):

```systemverilog
localparam N_BYTES = `XLEN / 8;                    // = 4 (XLEN=32)
localparam N_CTX   = N_BYTES >> LOG2_GROUP_SIZE;   // default: 4>>1 = 2
localparam CTX_W   = N_CTX * META_BITS;            // default: 2×1 = 2비트 (현행 동일)
```

`LOG2_GROUP_SIZE` 유효 범위: 0 ~ log2(N_BYTES).
- `0`: byte마다 독립 ctx (micro_ctx 4×, MXFP8 byte-level micro_exp 등 미래 용도)
- `1`: pair-shared (현행, MX9)
- `2`: word 전체 공유 (4-byte word 당 1개 ctx)

---

### 6.3 VX_tcu_micro_ctx.sv 변경

**Before**
```systemverilog
module VX_tcu_micro_ctx #(
    parameter NUM_WARPS = `NUM_WARPS,
    parameter MEXP_BITS = 1
) (
    input  wire [`NUM_THREADS-1:0][2*MEXP_BITS-1:0]  wr_mexp_a,
    input  wire [`NUM_THREADS-1:0][2*MEXP_BITS-1:0]  wr_mexp_b,
    output wire [`NUM_THREADS-1:0][2*MEXP_BITS-1:0]  rd_mexp_a,
    output wire [`NUM_THREADS-1:0][2*MEXP_BITS-1:0]  rd_mexp_b
);
    reg [2*MEXP_BITS-1:0] mexp_a_r [NUM_WARPS][`NUM_THREADS];
    reg [2*MEXP_BITS-1:0] mexp_b_r [NUM_WARPS][`NUM_THREADS];
```

**After**
```systemverilog
module VX_tcu_micro_ctx #(
    parameter NUM_WARPS       = `NUM_WARPS,
    parameter META_BITS       = 1,   // 포맷-비의존 ctx 엔트리 폭
    parameter LOG2_GROUP_SIZE = 1    // default=1 → GROUP_SIZE=2 (pair-shared)
) (
    input  wire [`NUM_THREADS-1:0][N_CTX*META_BITS-1:0]  wr_meta_a,
    input  wire [`NUM_THREADS-1:0][N_CTX*META_BITS-1:0]  wr_meta_b,
    output wire [`NUM_THREADS-1:0][N_CTX*META_BITS-1:0]  rd_meta_a,
    output wire [`NUM_THREADS-1:0][N_CTX*META_BITS-1:0]  rd_meta_b
);
    localparam N_BYTES = `XLEN / 8;
    localparam N_CTX   = N_BYTES >> LOG2_GROUP_SIZE;
    localparam CTX_W   = N_CTX * META_BITS;

    reg [CTX_W-1:0] meta_a_r [NUM_WARPS][`NUM_THREADS];
    reg [CTX_W-1:0] meta_b_r [NUM_WARPS][`NUM_THREADS];
```

포트명 `wr_mexp_a/b` → `wr_meta_a/b`, `rd_mexp_a/b` → `rd_meta_a/b`.
reset / read / write 로직은 `mexp_a_r` → `meta_a_r` 이름 변경 외 동일.

---

### 6.4 VX_tcu_operand_transformer.sv 변경

#### 파라미터 & localparam

**Before**
```systemverilog
parameter MEXP_BITS = 1

localparam MAX_MEXP = (1 << MEXP_BITS) - 1;
localparam FLAT_W   = 8 + MAX_MEXP;
```

**After**
```systemverilog
parameter META_BITS        = 1,
parameter LOG2_GROUP_SIZE  = 1

localparam N_BYTES   = `XLEN / 8;
localparam N_CTX     = N_BYTES >> LOG2_GROUP_SIZE;
localparam CTX_W     = N_CTX * META_BITS;
localparam MAX_SHIFT = (1 << META_BITS) - 1;   // meta 전체를 shift로 볼 때 최댓값
localparam FLAT_W    = 8 + MAX_SHIFT;           // default(META_BITS=1): 9 — 현행 동일
```

#### decode_meta() — fmt_s 기반 포맷별 해석 (placeholder)

```systemverilog
// 현재: passthrough (META_BITS=1, MX9만 존재)
// 3-level 포맷 추가 시 이 함수에 case 한 줄만 추가하면 됨.
// 예: TCU_3LEVEL_ID → return meta[META_BITS-1:1] + {{(META_BITS-1){1'b0}}, meta[0]};
function automatic logic [META_BITS-1:0] decode_meta(
    input logic [META_BITS-1:0] meta,
    input logic [3:0]           fmt_s
);
    `UNUSED_VAR(fmt_s)
    return meta;
endfunction
```

#### flatten_int8_word() — 2D 캐스팅 + LOG2_GROUP_SIZE 루프

**Before** (GROUP_SIZE=2 하드와이어, part-select 수식)
```systemverilog
function automatic logic [31:0] flatten_int8_word(
    input logic [31:0]            word,
    input logic [2*MEXP_BITS-1:0] mexp
);
    return {flatten_int8_byte(word[31:24], mexp[MEXP_BITS +: MEXP_BITS]),
            flatten_int8_byte(word[23:16], mexp[MEXP_BITS +: MEXP_BITS]),
            flatten_int8_byte(word[15:8],  mexp[0         +: MEXP_BITS]),
            flatten_int8_byte(word[7:0],   mexp[0         +: MEXP_BITS])};
endfunction
```

**After** (LOG2_GROUP_SIZE 파라미터 루프 + 2D packed array 캐스팅)
```systemverilog
function automatic logic [N_BYTES*8-1:0] flatten_int8_word(
    input logic [N_BYTES*8-1:0]  word,
    input logic [CTX_W-1:0]      meta,
    input logic [3:0]            fmt_s
);
    logic [N_BYTES*8-1:0] result;
    // 1D → 2D 캐스팅: meta_arr[i] = meta[i*META_BITS +: META_BITS]
    // 합성기가 wire routing으로 처리 (MUX 없음)
    logic [N_CTX-1:0][META_BITS-1:0] meta_arr;
    meta_arr = meta;
    for (integer b = 0; b < N_BYTES; b++) begin
        logic [META_BITS-1:0] eff_shift;
        // b >> LOG2_GROUP_SIZE: loop unroll 후 상수 → wire routing
        eff_shift = decode_meta(meta_arr[b >> LOG2_GROUP_SIZE], fmt_s);
        result[b*8 +: 8] = flatten_int8_byte(word[b*8 +: 8], eff_shift);
    end
    return result;
endfunction
```

> `LOG2_GROUP_SIZE=1, META_BITS=1` default: unroll 후 byte 0,1 → `meta_arr[0]`,
> byte 2,3 → `meta_arr[1]`. **현행 코드와 bit-identical**.

#### 호출부 변경 (fmt_s 추가 인자)

모든 `flatten_int8_word(word, mexp)` 호출 → `flatten_int8_word(word, meta, fmt_s)` 로 변경.
`fmt_s`는 `execute_if_in.data.op_args.tcu.fmt_s`.

---

### 6.5 VX_tcu_unit.sv 변경

instantiation 파라미터 이름 업데이트:

```systemverilog
// Before
VX_tcu_operand_transformer #(.MEXP_BITS(MEXP_BITS)) ...
VX_tcu_micro_ctx            #(.MEXP_BITS(MEXP_BITS)) ...

// After
VX_tcu_operand_transformer #(.META_BITS(META_BITS), .LOG2_GROUP_SIZE(LOG2_GROUP_SIZE)) ...
// micro_ctx는 OT 내부에서 직접 인스턴스화 → OT 파라미터만 최상위에서 전달
```

---

### 6.6 LDMICRO payload 변경 없음

현행 packing:
```
rs1_data[t][CTX_W-1:0] = {ctx[N_CTX-1], ..., ctx[1], ctx[0]}  (LSB-first)
```
CTX_W가 META_BITS와 LOG2_GROUP_SIZE에 따라 자동으로 결정되므로
LDMICRO 명령어 인코딩(opcode/funct7)은 변경 없음.
SW는 META_BITS와 LOG2_GROUP_SIZE 설정값에 맞춰 packing.

---

### 6.7 수정 파일 목록

| 파일 | 변경 내용 |
|------|-----------|
| `VX_tcu_micro_ctx.sv` | `MEXP_BITS`→`META_BITS`; `LOG2_GROUP_SIZE` 추가; 포트명/저장소명 변경 |
| `VX_tcu_operand_transformer.sv` | 동일 파라미터; `decode_meta()` 추가; `flatten_int8_word` 2D 캐스팅 루프화; 호출부 fmt_s 추가 |
| `VX_tcu_unit.sv` | instantiation 파라미터 이름 업데이트 |
| TB (tb_unit / tb_wmma) | **변경 없음** (default 파라미터 = 현행 동작 유지) |
| simx | **변경 없음** |

---

### 6.8 검증 계획

1. **기본값 회귀**: `META_BITS=1, LOG2_GROUP_SIZE=1` → 기존 tb_unit/tb_wmma 전체 PASS
2. **LOG2_GROUP_SIZE=2** (word 단위 공유):
   - 별도 TC: 4 bytes 모두 같은 mexp 공유 확인
3. **META_BITS=2** (2-bit shift):
   - INT8 × 4배 flatten, 포화 경계 TC

---

## 7. Phase D: MXFP8 E4M3 / E5M2 ✅ 완료

> **구현 방식 변경**: 계획 초안(Phase D)은 VX_tcu_fp.sv 내 FP8→BF16 변환 후 BHF에
> 전달하는 방식(Option B)이었으나, 실제 구현은 **VX_tcu_fedp_bhf.sv 내부 native FP8
> multiply (Option A)**로 결정·완료됨. 이하 실제 구현 기준으로 기술한다.

### 7.1 OT 변경사항 (없음)

FP8는 흡수할 2nd-level factor가 없으므로 OT에서 **특별한 처리 없음**.
OT 코드에서 FP8 (fmt_s=5, 6)은 do_mx9/is_flat_in 모두 해당 없어
default passthrough 분기로 자동 처리된다.

### 7.2 FEDP: Native FP8 Multiply in VX_tcu_fedp_bhf.sv ✅

**선택된 접근: Option A — native FP8 곱셈을 FEDP 내부에서 직접 수행**

VX_tcu_fp.sv의 BUFFER_EX 이후 a_row_r/b_col_r은 **원본 그대로** fedp_bhf에 전달된다.
FP8→BF16 변환은 fedp_bhf의 `g_prod` generate block 내부에서 수행된다.

```
VX_tcu_fp.sv:
  BUFFER_EX → a_row_r, b_col_r (원본 FP8 packed), fmt_s_r → fedp_bhf 직접 전달
  (변환 없음, fmt_s_bhf wire 없음)

VX_tcu_fedp_bhf.sv (g_prod 내부, element i per-lane):
  wire [7:0] fp8_byte_a = a_row16[i][15:8];  // FP8[0] at bits[15:8]
  wire [7:0] fp8_byte_b = b_col16[i][15:8];

  // E4M3: {s[7], e[6:3], m[2:0]}, bias=7
  // → 4b×4b mantissa multiply → FP32 result → pipelined FMT_DELAY cycles
  // → fNToRecFN → mux at FMUL stage 출력과 동일 타이밍

  // E5M2: {s[7], e[6:2], m[1:0]}, bias=15
  // → 3b×3b mantissa multiply → FP32 result → 동일 pipeline

  // case (fmt_s) 에 3'd5(E4M3), 3'd6(E5M2) 분기 추가
  // BHF BF16 결과와 cycle-accurate으로 mux
```

**FP8→BF16 함수**: VX_tcu_fp.sv에 원본 코드가 블록 주석으로 보존 (참고용).
실제 계산에는 사용되지 않음.

**FP8 레지스터 패킹 규약** (불변):

```
32-bit XLEN word (FP8 모드)
  ┌──────────────────┬──────────────────┐
  │  FP8[1] (8-bit)  │  FP8[0] (8-bit)  │
  │  bits[31:24]     │  bits[15:8]      │
  │  (각 16-bit 슬롯의 상위 8-bit 사용)   │
  └──────────────────┴──────────────────┘
```

word당 FP8 2개 → native multiply 2회. BF16/FP16과 동일 처리량.

#### FP8 E4M3 native multiply 수식

```
입력: a = {sa[1], ea[3:0], ma[2:0]}, b = {sb[1], eb[3:0], mb[2:0]}  (bias=7)

4b×4b mantissa multiply:
  maf = {1'b1, ma};  mbf = {1'b1, mb};  pm = maf * mbf;  // 8-bit product
  fexp = ea + eb + 113 + pm[7]   // 113 = 127(FP32 bias) - 14(2×bias)
  fman = pm[7] ? {pm[6:0], 16'b0} : {pm[5:0], 17'b0}

Special cases:
  ea==0 || eb==0 → ±0 (flush-to-zero)
  ea==4'hF: ma≠0 → qNaN; ma==0 → saturated max {s, 8'hFE, 7'h7F}
  eb==4'hF: same
```

#### FP8 E5M2 native multiply 수식

```
입력: a = {sa[1], ea[4:0], ma[1:0]}, b = {sb[1], eb[4:0], mb[1:0]}  (bias=15)

3b×3b mantissa multiply:
  maf = {1'b1, ma};  mbf = {1'b1, mb};  pm = maf * mbf;  // 6-bit product
  fexp = ea + eb + 97 + pm[5]    // 97 = 127 - 30(2×bias)
  fman = pm[5] ? {pm[4:0], 18'b0} : {pm[3:0], 19'b0}

Special cases:
  ea==0 || eb==0 → ±0
  ea==5'h1F: ma==0 → ±Inf; ma≠0 → qNaN
  eb==5'h1F: same
```

### 7.3 HANDLE_SUBNORMAL 파라미터

```systemverilog
parameter HANDLE_SUBNORMAL = 0   // 0: flush to zero (default, inference)
                                 // 1: full CLZ normalization (spec compliance)
```

### 7.4 FEDP BHF post-accumulation exp_total 스케일

`VX_tcu_fedp_bhf.sv`에 exp_total 스케일 스테이지가 이미 구현되어 있다.
리덕션 후 FP32 결과의 exponent에 exp_total을 combinational하게 가산한다.
레이턴시 변화 없음 (13cy 유지).

**Phase E 이후**: exp_total은 tcu_args_t의 scale_A[i] + scale_B[j] - 254로 계산되어
BUFFER_EX 후 exp_total_r로 전달된다 (per-(i,j), §8.1 참조).

### 7.5 수정 파일 목록 (실제 구현 기준)

| 파일 | 변경 내용 |
|------|-----------|
| `VX_tcu_pkg.sv` | `TCU_FP8E4M3_ID=5`, `TCU_FP8E5M2_ID=6` 상수 (이미 존재) |
| `VX_tcu_fp.sv` | `HANDLE_SUBNORMAL` 파라미터; FP8→BF16 함수 블록 주석 보존; fmt_s_r 직접 fedp_bhf 전달; `UNUSED_VAR`에서 `fmt_s`, `exp_total` 제거 |
| `VX_tcu_fedp_bhf.sv` | **g_prod 내 native FP8 multiply 추가** (E4M3/E5M2); VX_pipe_register FMT_DELAY; case 3'd5/3'd6 분기 |
| `VX_tcu_operand_transformer.sv` | **변경 없음** |
| `sim/simx/tensor_unit.cpp` | `fp8e4m3_to_float()` / `fp8e5m2_to_float()` 헬퍼; `ag_wmma()` FP8 분기 (FP8→float + dot + ldexp(exp_total[i][j]) + C) |
| `hw/rtl/tcu/tb_wmma/tb_tcu_wmma.sv` | FP8 TC 3개 (E4M3_wmma/neg, E5M2_wmma) |

### 7.6 레이턴시 분석 (TCU_BHF, TCU_TC_K=2)

```
LEVELS = clog2(2×TCU_TC_K) = 2
FRED_LATENCY = 2 × (FADD(2) + FRND(1)) = 6cy
TOTAL_LATENCY = (FMUL(2)+FRND(1)) + 1 + FRED(6) + (FADD(2)+FRND(1)) = 13cy
  ※ exp_total shift는 FADD 전 combinational 처리 → 추가 사이클 없음

[현재 Phase 10 / Phase D 후 동일]
  BHF FEDP:  13cy  (변화 없음)
  FP path:   OT(1) + VX_tcu_fp(14) = 15cy  (변화 없음)
  INT path:  OT(1) + VX_tcu_int(6) = 7cy   → TCU_UNIT_PIPE_LATENCY=7
```

FP path는 이미 INT path보다 레이턴시가 크다.
scoreboard는 commit writeback 신호 기반이므로 FP/INT latency 불일치가 정합성에 영향 없다.

compile-time assert (`VX_tcu_unit.sv`) — Phase D에서 추가 권장:

```systemverilog
`STATIC_ASSERT(PIPE_LATENCY_FP == 14,
    ("VX_tcu_fp BHF latency mismatch: expected 14cy (total FP=OT(1)+14=15), got %0d", PIPE_LATENCY_FP))
```

---

## 8. Phase E: MXFP6 / MXFP4 (향후)

### MXFP6 E2M3 / E3M2

- Phase D와 동일한 패턴: OT passthrough, FEDP front-end에서 BF16 변환
- `VX_tcu_fp.sv`에 `fp6e2m3_to_bf16()`, `fp6e3m2_to_bf16()` 추가
- Phase D의 exp_total 스케일 스테이지 재사용 (FEDP 추가 수정 없음)
- **핵심 과제**: FP6은 6-bit로 byte 경계 비정렬. dense packing 대신
  **8-bit per element packing** 규약을 SW/ISA 레벨에서 강제하면 구현이 단순해짐.

### MXFP4 E2M1 / NVFP4

- 선택지:
  - (a) FP path: OT passthrough → FEDP front-end FP4→BF16 (density 2배 손실)
  - (b) INT path: OT에서 FP4→INT4 변환 + fmt_s 패치 (MX9 방식, industry 표준 접근)
- Phase E에서 최종 결정
- NVFP4: MXFP4와 element 구조 동일, block scale 인코딩(UE8M0 vs E8M0) 차이만 존재

### Phase E 착수 전 선행 작업

1. **fmt_s 재정의**: `{bit[3]: path, bit[2:1]: class, bit[0]: subtype}` 검토
2. **OT/FEDP combinational depth timing 분석**

---

## 9. FP8 Native FEDP ✅ 구현 완료 (Phase D에서 달성)

Phase D에서 FP8→BF16-then-BHF 방식이 아닌 **native FP8 multiply**를
VX_tcu_fedp_bhf.sv 내부에 직접 구현했다. §7.2 참조.

```
현재 FP8 pathway (Phase D 이후):
  OT → [passthrough] → VX_tcu_fp → VX_tcu_fedp_bhf
                                     (내부 g_prod: fmt_s_r==5/6 → native FP8 × FP8 → FP32)
```

OT가 flattening만 담당하므로 FEDP 내부 변경에 OT 수정 불필요 — 설계 원칙 유지됨.

> **처리량**: word당 FP8 2개 (BF16과 동일). 4개/word 밀도 최적화는 TCU_TC_K 2배 확장이
> 필요하여 미래 과제로 남긴다.

---

## 10. Phase E: per-row/col scale 벡터 (구현완료, 검증 대기)

Avant-Garde 논문의 per-block per-row/column scale을 HW로 지원한다.
기존 구현은 tile 단위 단일 scalar exp_total을 OT에서 계산하여 payload에 넣었으나,
논문에서는 A matrix의 각 행(row), B matrix의 각 열(col)마다 독립적인 E8M0 스케일을 가진다.

### 10.1 구조 변경 요약

#### INST_ARGS_BITS 확장 (EXT_AG_TCU_ENABLE 전용)

```
기존: INST_ARGS_BITS = ALU_TYPE_BITS(2) + XLEN(32) + 3 = 37b
변경: INST_ARGS_BITS = 37 + 16 = 53b  (EXT_AG_TCU_ENABLE 시)
  +16b = scale_A[TC_M×8b] + scale_B[TC_N×8b]
       = [15:0] + [15:0] = 32b 신규 필드 (exp_total 10b + padding 6b = 16b 교체 → +16b 순증)
```

다른 arg 타입(alu, fpu, lsu, csr, wctl)은 자동으로 `__tcu_scale_pad` 16b 패딩 추가.

#### tcu_args_t 변경

```systemverilog
// Phase E 이전 (EXT_AG_TCU_ENABLE):
logic [(INST_ARGS_BITS-31)-1:0]  __padding;   // 6b
logic signed [9:0]               exp_total;   // OT 계산 스칼라

// Phase E 이후:
logic [15:0]  scale_A;   // [i*8+:8] = scale_A[i], E8M0 unsigned (TC_M=2 → 16b)
logic [15:0]  scale_B;   // [j*8+:8] = scale_B[j], E8M0 unsigned (TC_N=2 → 16b)
// exp_total 제거
```

#### VX_tcu_scale_ctx.sv: scalar → vector 저장소

```systemverilog
// 기존: reg [TCU_EXP_BITS-1:0] scale_a_r/scale_b_r [NUM_WARPS]
// 변경: reg [TC_M*TCU_EXP_BITS-1:0] scale_A_r [NUM_WARPS]
//       reg [TC_N*TCU_EXP_BITS-1:0] scale_B_r [NUM_WARPS]

// LDSCALE packing (Phase E):
//   [7:0]   = scale_A[0]   (A row 0)
//   [15:8]  = scale_A[1]   (A row 1)
//   [23:16] = scale_B[0]   (B col 0)
//   [31:24] = scale_B[1]   (B col 1)
```

#### OT: exp_total_comb 제거, scale 벡터 payload 기록

```systemverilog
// 기존: ot_data_next.op_args.tcu.exp_total = exp_total_comb;
// 변경: ot_data_next.op_args.tcu.scale_A = rd_scale_A;
//       ot_data_next.op_args.tcu.scale_B = rd_scale_B;

// MX9 보정: -10을 scale_A/B 각각에서 -5씩 분배
//   (scale_A[i]-5) + (scale_B[j]-5) - 254 = orig_exp_total - 10 ✓
```

#### VX_tcu_fp.sv / VX_tcu_int.sv: per-(i,j) exp_total

```systemverilog
// 기존 BUFFER_EX: exp_total_r 버퍼
// 변경: scale_A_ij_r, scale_B_ij_r 버퍼 (slice from payload)

wire signed [TCU_EXP_TOTAL-1:0] exp_total_r =
    $signed(TCU_EXP_TOTAL'({2'b0, scale_A_ij_r}))
  + $signed(TCU_EXP_TOTAL'({2'b0, scale_B_ij_r}))
  - $signed(TCU_EXP_TOTAL'(2 * TCU_EXP_BIAS));
// exp_total_r은 FEDP로 전달 (인터페이스 변경 없음)
```

### 10.2 simx 변경

```cpp
// ScaleContext: scalar → per-row/col vector
//   scale_A[wid][i], scale_B[wid][j]  (cfg::tcM, cfg::tcN 크기)

// ldscale() packing 변경:
//   sa[0]=[7:0], sa[1]=[15:8], sb[0]=[23:16], sb[1]=[31:24]

// ag_wmma(): exp_total = scale_ctx_.exp_total(wid, i, j) (per-(i,j))
```

### 10.3 Testbench 변경

```systemverilog
// fire_ldscale(): 기존 {16'b0, scale_b, scale_a} → {sB1, sB0, sA1, sA0}
//   scalar 유지: sA0=sA1=scale_a, sB0=sB1=scale_b (기존 TC 호환)

// fire_ldscale_vec(): 신규 — per-row/col 독립 설정
task automatic fire_ldscale_vec(sA0, sA1, sB0, sB1);
```

### 10.4 수정 파일 목록

| 파일 | 변경 내용 |
|------|-----------|
| `VX_gpu_pkg.sv` | INST_ARGS_BITS +16b (AG_TCU_ENABLE 시); alu_args_t 16b 패드; tcu_args_t: exp_total→scale_A/B |
| `VX_tcu_scale_ctx.sv` | scalar → vector 저장소; packing 변경 |
| `VX_tcu_operand_transformer.sv` | exp_total_comb 제거; rd_scale_A/B → payload; MX9 -10 분배 |
| `VX_tcu_fp.sv` | scale_A_ij_r/scale_B_ij_r 버퍼; per-(i,j) exp_total_r |
| `VX_tcu_int.sv` | 동일 |
| `sim/simx/tensor_unit.cpp` | ScaleContext vector화; ldscale() packing; ag_wmma() per-(i,j) |
| `hw/rtl/tcu/tb_wmma/tb_tcu_wmma.sv` | fire_ldscale() packing 수정; fire_ldscale_vec() 추가 |

### 10.5 검증 (대기 중)

```bash
# L5 tb_wmma (기존 20TC + 신규 per-row/col TC)
cd hw/rtl/tcu/tb_wmma && make && make run

# simx e2e (LDSCALE packing 변경 포함)
cd tests/regression/sgemm_ag_tcu && make test-simx
```

기존 TC가 모두 scalar uniform scale (sA0=sA1, sB0=sB1) 이므로 결과 동일해야 함.

---

## 11. 호환성 체크리스트

| 항목                         | Phase A                | Phase B                 | Phase C                       | Phase D (FP8)             | Phase E (scale vec) |
|------|:-------:|:-------:|:-------:|:-------:|:-------:|
| FP32/FP16/BF16 WMMA         | ✅                     | ✅                     | ✅ META_BITS=1 → no-op        | ✅ exp_total=0             | ✅ scale=127 → exp=0 |
| MX9 WMMA                    | ✅ MEXP_BITS=1 → no-op | ✅ FLAT 시퀀스          | ✅ LOG2_GROUP_SIZE=1 → no-op  | ✅                        | ✅ -10 분배 |
| MXINT8/I8 WMMA              | ✅                     | ✅ FLAT 시퀀스          | ✅                            | ✅                        | ✅ scalar uniform |
| FP8 WMMA                    | -                      | -                      | -                             | ✅ native FEDP            | ✅ per-(i,j) exp |
| LDSCALE/LDTILE/LDMICRO      | ✅                     | ✅                     | ✅ 포트명 변경 (wr_meta_a/b)  | ✅                        | ⚠️ packing 변경 |
| fire_ldscale TB              | ✅                     | ✅                     | ✅                            | ✅                        | ⚠️ packing 수정 |
| pe_switch 라우팅             | ✅                     | ✅                     | ✅ 변경 없음                   | ✅ FP8 bit[3]=0 → FP path | ✅ 변경 없음 |
| VX_tcu_operand_transformer  | ⚠️ MEXP_BITS 추가       | ⚠️ is_nop_in FLAT 포함 | ⚠️ META_BITS/LOG2_GROUP_SIZE  | ✅ 변경 없음                | ⚠️ exp_total 제거 |

### 위험 요소 (현재 활성)

1. **Phase E — INST_ARGS_BITS**: EXT_AG_TCU_ENABLE 외 빌드에서 INST_ARGS_BITS 불변.
   non-AG 빌드 및 다른 arg 타입(alu, fpu 등) PACKAGE_ASSERT 통과 필요.

2. **Phase E — LDSCALE packing 변경**: 기존 simx/rtlsim/커널 LDSCALE 발행 측
   모두 새 packing으로 업데이트 필요. {sB1, sB0, sA1, sA0} 순서 확인 필수.

3. **Phase E — TB fire_ldscale scalar 호환**: sA0=sA1=scale_a 가정.
   TC_M≠2 이거나 per-row 독립 TC 시 fire_ldscale_vec 사용.

4. **Phase E — MX9 -10 분배 오버플로**: scale_A[i]-5 시 underflow(0→251 wrap) 위험.
   E8M0 unsigned 8b이므로 scale < 5이면 오동작. 일반적인 사용 범위에서 문제 없음.

---

## 12. (구) 호환성 체크리스트

> **이 섹션은 Phase D까지의 위험 요소 기록이다. 최신 사항은 §11 참조.**
   BF16 변환 시 NaN(m≠0)과 구분하여 `{s, 8'hFE, 7'h7F}` 출력 필요.

8. **Phase D — native FP8 접근**: fmt_s_bhf 패치 불필요.
   fedp_bhf 내부 case(fmt_s_r)에서 3'd5/3'd6을 직접 처리.

---

## 11. 검증 계획

### Phase B 검증 (FLAT)

| TC | 검증 항목 |
|----|-----------|
| TC_FLAT_basic | FLAT 후 tile register 값이 flattened INT8인지 확인 |
| TC_FLAT_then_wmma | LDTILE → LDMICRO → FLAT → WMMA 결과 = 기존 LDMICRO → WMMA와 동일 |
| TC_FLAT_reuse | FLAT 1회 후 WMMA 반복 시 결과 일관성 |
| TC_FLAT_stale | FLAT 후 LDMICRO 재실행 → re-FLAT 없이 WMMA 시 stale 동작 확인 |

### Phase C 신규 TC

| TC | 검증 항목 |
|----|-----------|
| TC_META_default | META_BITS=1, LOG2_GROUP_SIZE=1 → 기존 전체 TC PASS (regression) |
| TC_GS2_shared | LOG2_GROUP_SIZE=2 (word 단위): 4 bytes 모두 동일 mexp 적용 확인 |
| TC_META2_shift | META_BITS=2 (2-bit shift): INT8 ×4 flatten, 포화 경계 검증 |

### Phase D 신규 TC

| TC | 포맷 | 검증 항목 |
|----|------|-----------|
| TC_FP8E4M3_normal | MXFP8 E4M3 | 정상값 MAC, exp_total=0 |
| TC_FP8E4M3_scale | MXFP8 E4M3 | exp_total≠0 (block scale 적용) |
| TC_FP8E4M3_subnormal | MXFP8 E4M3 | HANDLE_SUBNORMAL=0 → flush-to-zero |
| TC_FP8E4M3_nan | MXFP8 E4M3 | NaN 전파 |
| TC_FP8E5M2_normal | MXFP8 E5M2 | 정상값 MAC |
| TC_FP8E5M2_inf | MXFP8 E5M2 | Infinity 처리 |

### Regression

- Phase A 후: MEXP_BITS=1 regression (L4 7/7 + L5 9/9) ✅ 완료
- Phase B 후: FLAT TC (L4 13/13, L5 13/13) ✅ 완료
- Phase C 후: META_BITS=1/LOG2_GROUP_SIZE=1 full regression ✅ 완료 (L4 13/13, L5 20/20)
- Phase D 후: FP8 TC + full regression ✅ 완료 (L5 20/20 PASS, simx/rtlsim PASS)
- Phase E 후: 기존 20TC + 검증 대기 ⏳

---

## 13. 구현 순서 요약

```
Phase A (micro_exp N-bit 파라미터화)  ✅ 완료
  ├── VX_tcu_micro_ctx.sv          : MEXP_BITS 파라미터화
  ├── VX_tcu_operand_transformer.sv: flatten_int8_byte N-bit 일반화
  ├── VX_tcu_unit.sv               : MEXP_BITS 전달
  └── MEXP_BITS=1 regression (L4 7/7, L5 9/9) ✅

Phase B (FLAT 명령어 — 논문 구조 정합)  ✅ 완료
  ├── VX_tcu_pkg.sv                : TCU_OP_FLAT 추가
  ├── VX_tcu_uops.sv               : FLAT UOP 시퀀싱 (NRA + NRB sequential)
  ├── VX_tcu_unit.sv               : FLAT short commit path (OT 출력 → commit, FEDP bypass)
  ├── VX_tcu_operand_transformer.sv: is_flat_in 분기 신규; is_nop_in에 FLAT 포함
  ├── simx                         : ldflat() 구현
  ├── TB                           : LDMICRO → FLAT → WMMA 시퀀스; FLAT TC 추가
  └── FLAT TC + full regression (L4 13/13, L5 13/13) ✅

Phase C (META_BITS / LOG2_GROUP_SIZE 파라미터화)  ✅ 완료
  ├── VX_tcu_micro_ctx.sv          : MEXP_BITS→META_BITS; LOG2_GROUP_SIZE; 포트명 변경
  ├── VX_tcu_operand_transformer.sv: 동일 파라미터; decode_meta(); flatten_int8_word 루프화
  ├── VX_tcu_unit.sv               : instantiation 파라미터 이름 업데이트
  └── META_BITS=1/LOG2_GROUP_SIZE=1 full regression (L4 13/13, L5 20/20) ✅

Phase D (MXFP8 — native FP8 multiply in FEDP)  ✅ 완료
  ├── VX_tcu_fedp_bhf.sv           : g_prod 내 E4M3/E5M2 native multiply 추가
  │                                  (FP8→BF16 변환 방식 미사용 → 블록 주석 보존)
  ├── VX_tcu_fp.sv                 : HANDLE_SUBNORMAL 파라미터; UNUSED_VAR 정리;
  │                                  FP8→BF16 함수 블록 주석 보존 (참고용)
  ├── VX_tcu_operand_transformer.sv: 변경 없음
  ├── sim/simx/tensor_unit.cpp     : fp8_to_float() 헬퍼; ag_wmma() FP8 분기
  ├── tb_wmma/tb_tcu_wmma.sv       : FP8 TC 3개 (E4M3×2, E5M2×1)
  └── FP8 TC + full regression (L5 20/20, simx 11/11, rtlsim 7/7) ✅

Phase E (per-row/col scale 벡터)  ⏳ 구현완료, 검증 대기
  ├── VX_gpu_pkg.sv                : INST_ARGS_BITS +16b; alu_args_t pad; tcu_args_t scale_A/B
  ├── VX_tcu_scale_ctx.sv          : scalar → vector 저장소; packing 변경
  ├── VX_tcu_operand_transformer.sv: exp_total_comb 제거; scale_A/B → payload; MX9 -10 분배
  ├── VX_tcu_fp.sv                 : per-(i,j) scale_A_ij_r/scale_B_ij_r BUFFER_EX; exp_total_r
  ├── VX_tcu_int.sv                : 동일
  ├── sim/simx/tensor_unit.cpp     : ScaleContext vector화; ldscale() packing; ag_wmma() per-(i,j)
  ├── tb_wmma/tb_tcu_wmma.sv       : fire_ldscale() packing 수정; fire_ldscale_vec() 추가
  └── ⏳ 검증 대기: make run (tb_wmma 20/20) + make test-simx

Phase F (MXFP6 / MXFP4, 향후)
  ├── fmt_s 인코딩 재정의 검토
  ├── VX_tcu_fp.sv                 : fp6_to_bf16() 추가
  ├── FP4 경로 결정 후 구현
  └── tb 추가 + full regression
```
