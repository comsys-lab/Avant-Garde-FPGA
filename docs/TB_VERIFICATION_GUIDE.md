# AG-TCU Testbench 검증 가이드

AG-TCU 전체 파이프라인의 testbench 구조, TC 목록, 파이프라인 I/O, 미구현 검증 항목을 정리한다.

---

## 1. 검증 계층 구조

```
L9  tb_schedule ✅ 6/6    — VX_schedule 단독
L8b tb_fetch    ✅ 5/5    — VX_fetch 단독
──────────────────────────────────────────────────────────────────
L8  tb_decode   ──── VX_decode 단독       (decode_if 직접 샘플링)
L7  tb_issue    ──── VX_issue 단독        (dispatch_if 직접 카운팅)
L6  tb_execute  ──── VX_execute + VX_commit
L5  tb_wmma     ──── VX_tcu_unit (full K-accumulation)
L4  tb_unit     ──── VX_tcu_unit (single WMMA dispatch)
L2  tb_int      ──── VX_tcu_int (FEDP unit)
```

각 레벨은 해당 모듈만 단독으로 검증한다. 넓은 범위의 통합 검증은 tb_pipeline (L9p)이 담당한다.

> **설계 원칙**: 각 TB가 딱 한 가지 DUT를 책임지도록 하여 실패 시 버그 위치 국지화가 용이하다.

---

## 2. 파이프라인 I/O 전체 매핑

GPU instruction 입력부터 writeback 출력까지 각 단계의 입출력 인터페이스.

### GPU 입력 형식

32-bit RISC-V 명령어 (opcode=`7'h0B`):

```
[31:25] funct7   [24:20] rs2  [19:15] rs1  [14:12] funct3  [11:7] rd  [6:0] opcode
```

| 명령 | funct7 | rs1 | rs2 | rd | 비고 |
|------|--------|-----|-----|-----|------|
| WMMA | `7'h02` | A-tile reg | B-tile reg | D-tile reg (fmt_d=rd[3:0]) | fmt_s=rs1[3:0] |
| LDSCALE | `7'h06` | scale reg | — | — | rs1_data[0]={scale_b, scale_a} |
| LDTILE_A | `7'h07` | src reg | — | A-tile rd | tile_type=A |
| LDTILE_B | `7'h0F` | src reg | — | B-tile rd | tile_type=B |
| LDTILE_C | `7'h17` | src reg | — | C-tile rd | tile_type=C |

---

### Stage 1: VX_schedule → VX_fetch

**출력: `schedule_if` (schedule_t)**

```systemverilog
typedef struct packed {
    logic [UUID_WIDTH-1:0]      uuid;     // 45b — 명령 고유 ID
    logic [NW_WIDTH-1:0]        wid;      // warp index (0..NUM_WARPS-1)
    logic [`NUM_THREADS-1:0]    tmask;    // active thread mask
    logic [PC_BITS-1:0]         PC;       // program counter (byte addr)
} schedule_t;
```

**주요 내부 상태:**

| 신호 | 설명 |
|------|------|
| `active_warps` | 활성 warp 비트마스크 (kernel launch 시 설정) |
| `stalled_warps` | WMMA/branch 발행 후 stall된 warp 마스크 |
| `warp_pcs[NUM_WARPS]` | warp별 현재 PC |
| `thread_masks[NUM_WARPS]` | warp별 thread mask |
| `schedule_wid` | 이번 사이클에 선택된 warp |

---

### Stage 2: VX_fetch → VX_decode

**입력:** `schedule_if` (schedule_t)
**출력: `fetch_if` (fetch_t)**

```systemverilog
typedef struct packed {
    logic [UUID_WIDTH-1:0]          uuid;
    logic [NW_WIDTH-1:0]            wid;
    logic [`NUM_THREADS-1:0]        tmask;
    logic [PC_BITS-1:0]             PC;
    logic [31:0]                    instr;   // I-cache에서 읽은 명령어 raw bits
} fetch_t;
```

**내부 동작:**
1. schedule_if.PC → I-cache 요청
2. per-warp tag store에 `{PC, tmask}` 저장 (wid를 tag key로 사용)
3. I-cache 응답 수신 시 tag store에서 `{rsp_PC, rsp_tmask}` 복구
4. `{uuid, wid, tmask, PC, instr}` → fetch_if

---

### Stage 3: VX_decode → VX_issue

**입력:** `fetch_if` (fetch_t)
**출력: `decode_if` (decode_t)**

```systemverilog
typedef struct packed {
    logic [UUID_WIDTH-1:0]          uuid;
    logic [NW_WIDTH-1:0]            wid;
    logic [`NUM_THREADS-1:0]        tmask;
    logic [PC_BITS-1:0]             PC;
    logic [EX_BITS-1:0]             ex_type;    // EX_ALU=0, EX_TCU=5, ...
    logic [INST_OP_BITS-1:0]        op_type;    // INST_TCU_WMMA 등
    op_args_t                       op_args;    // tcu_args_t 포함 (42b)
    logic                           wb;         // writeback enable
    logic [NUM_SRC_OPDS-1:0]        used_rs;    // [2]=rs3, [1]=rs2, [0]=rs1
    logic [NUM_REGS_BITS-1:0]       rd, rs1, rs2, rs3;
} decode_t;
```

**TCU 명령 decode 규칙 (Phase 10):**

| 명령  | ex_type | op_type | tcu_op | used_rs | wb |
|-------|---------|---------|--------|---------|-----|
| WMMA | EX_TCU(5) | INST_TCU_WMMA | 3'b000 | 3'b111 | 1 |
| LDSCALE | EX_TCU(5) | INST_TCU_WMMA | 3'b001 | 3'b001 | 1 |
| LDTILE_A/B/C | EX_TCU(5) | INST_TCU_WMMA | 3'b010 | 3'b001 | 0 |
| **LDMICRO** (Phase10) | EX_TCU(5) | INST_TCU_WMMA | **3'b011** | **3'b011** | **0** |

**tcu_args_t 주요 필드:**

```systemverilog
typedef struct packed {
    ...                                         // padding
    logic signed [TCU_EXP_TOTAL-1:0] exp_total; // 10b — OT가 채움 (decode 시 0)
    tcu_op_e                          tcu_op;    // 3b: WMMA/LDSCALE/LDTILE/LDMICRO (Phase10)
    logic [3:0]                       fmt_d;     // rd[3:0]에서 추출
    logic [3:0]                       fmt_s;     // rs1[3:0]에서 추출
    logic [3:0]                       step_n;    // rs2[3:0]에서 추출 (WMMA)
    logic [3:0]                       step_m;    // rs3[3:0]에서 추출 (WMMA)
} tcu_args_t;
```

---

### Stage 4: VX_issue → VX_execute

**입력:** `decode_if` (decode_t)
**출력: `dispatch_if[EX_UNITS * ISSUE_WIDTH]` (dispatch_t)**

```systemverilog
// dispatch_t (VX_tcu_unit 관점)
uuid, wis[ISSUE_WIS_W], sid[SIMD_IDX_W],
tmask[SIMD_WIDTH], PC,
op_type, op_args,
wb, rd,
rs1_data[SIMD_WIDTH][XLEN],   // A-tile 또는 scale 값
rs2_data[SIMD_WIDTH][XLEN],   // B-tile
rs3_data[SIMD_WIDTH][XLEN],   // C-tile (accumulator)
sop, eop                       // WMMA: sop=첫 uop, eop=마지막 uop
```

**VX_issue 내부 단계:**

1. **ibuffer** — decode_t 버퍼링
2. **uop_sequencer** — WMMA → `TCU_UOPS`개 μop (sop/eop 마킹)
   LDSCALE → 1개 (확장 없음)
3. **scoreboard** — RAW 해저드 검출 → stall
4. **operands** — GPR read → rs{1,2,3}_data 패킹
5. **dispatch** — ex_unit 선택 후 `dispatch_if[EX_TCU * ISSUE_WIDTH]`로 전송

---

### Stage 5: VX_execute (TCU 경로)

**내부 흐름:**

```
dispatch_if
    ↓
VX_dispatch_unit      → per_block_execute_if (tcu_exe_t)
    ↓
VX_tcu_unit
  ├── VX_tcu_operand_transformer (OT, 1cy)
  │     - LDSCALE: scale_a/b → scale_ctx[wid] 저장
  │     - WMMA INT: MX9 flatten (byte={mexp,m7} → m7 << mexp)
  │     - WMMA FP:  MX9 → BF16 변환 (mx9_fp_mode=1 시)
  │     - exp_total 계산: scale_a + scale_b - 254 → op_args.tcu.exp_total
  │     - LDSCALE/LDTILE hazard lock (inflight 동안 stall)
  │     ↓
  ├── pe_switch (0cy)
  │     - fmt_s[3]=1 (INT) → VX_tcu_int
  │     - fmt_s[3]=0 (FP)  → VX_tcu_fp
  │     ↓
  ├── VX_tcu_int (5cy)   또는   VX_tcu_fp (backend 의존)
  │     INT: FEDP 연산 (MUL 2cy + ACC 2cy + mdata 1cy)
  │     FP:  BF16/FP16 FEDP
  │     ↓
  └── VX_gather_unit    → per_block_result_if (tcu_res_t)
```

**tcu_res_t (결과):**

```systemverilog
uuid, wid, tmask, PC,
wb, rd,
data[NUM_TCU_LANES][XLEN],   // INT32 결과 (D-tile 1 word)
pid,                          // partial ID (K-accumulation용)
sop, eop
```

**지연:**

| 경로 | 지연 |
|------|------|
| INT: OT + tcu_int | 1 + 5 = 6 사이클 |
| FP: OT + tcu_fp (BHF) | 1 + (backend 의존) |

---

### Stage 6: VX_commit → writeback

**입력:** `commit_if[EX_UNITS * ISSUE_WIDTH]` (commit_t)
**출력: `writeback_if[ISSUE_WIDTH]` (writeback_t)**

```systemverilog
typedef struct packed {
    logic [NW_WIDTH-1:0]                wid;   // 절대 warp ID (wis → wid 복원)
    logic [`NUM_THREADS-1:0]            tmask;
    logic [PC_BITS-1:0]                 PC;
    logic [NUM_REGS_BITS-1:0]           rd;
    logic [`SIMD_WIDTH-1:0][`XLEN-1:0]  data;
    logic                               sop;
    logic                               eop;
} writeback_t;
```

중재 우선순위: `EX_ALU > EX_TCU > EX_LSU > EX_SFU`

---

## 3. TC 목록 및 커버리지 분석

### L2: tb_tcu_int (VX_tcu_int 단독)

DUT: `VX_tcu_int` — exp_total 적용된 FEDP 연산 유닛

| TC | 이름 | 검증 내용 | 적절성 |
|----|------|---------|--------|
| TC1 | ones_exp0 | A=B=1, exp=0 → dot=8 | ✅ 기본 동작 |
| TC2 | ones_exp4 | exp=+4 → dot<<4=128 | ✅ 좌측 시프트 |
| TC3 | ones_accum | C=100 → result=108 | ✅ accumulator |
| TC4 | asymmetric | {2,3}×{1,4} | ✅ 비대칭 배열 |
| TC5 | neg_dot | 음수 × 양수 | ✅ 부호 처리 |
| TC6 | pos_saturation | (-128)×(-128)×exp=14 → 포화 | ✅ 오버플로 |
| TC7 | rshift4_ones | exp=-4 → dot>>>4=0 | ✅ 우측 시프트 |
| TC8 | MX_style_block | mantissa={1,2,3,4}×{1,1,1,1}, exp=6 | ✅ MX 패턴 |
| TC9 | neg_accum | dot=8 + C(-200) = -192 | ✅ 음수 누산 |
| TC10 | zero_dot | B=0 → D=C | ✅ zero 처리 |

**빠진 항목:**
- 우측 시프트 결과 ≥ 1 케이스 (TC7은 결과 0) → exp=-2, A=B=4 → dot>>2=4 필요
- eop=0인 중간 uop (K-accumulation 내부 상태) — L2에서는 검증 불가 (상위 TB에서 처리)

---

### L4: tb_tcu_unit (VX_tcu_unit 단일 dispatch)

DUT: `pe_switch → {VX_tcu_int | VX_tcu_fp}`
이전 Phase와 달리 OT 포함 (Phase 9 기준)

| TC | 이름 | 검증 내용 | 적절성 |
|----|------|---------|--------|
| TC1 | ones_exp0 | MX9: byte=0x01→flat=+1, dot=8 | ✅ OT flatten |
| TC2 | ones_exp4 | exp=+4, flatten 후 shift | ✅ |
| TC3 | ones_accum | C=100 → 108 | ✅ |
| TC4 | asymmetric | 2×2 타일 | ✅ |
| TC5 | neg_dot | byte=0x7F→flat=-1 | ✅ MX9 음수 |
| TC6 | pos_saturation | byte=0xC0, exp=14 → 포화 | ✅ |
| TC7 | rshift2_ones | exp=-2 → 2 | ✅ 우측 시프트 ≥1 |
| TC8 | MX_style | 블록 mantissa 패턴 | ✅ |
| TC9 | neg_accum | C=-200 | ✅ |
| TC10 | zero_dot | A=0 → D=C | ✅ |
| TC11 | max_exp | exp=+14 → 131072 (포화 없음) | ✅ 경계 |
| TC12 | metadata_passthrough | wb/rd 메타데이터 통과 | ✅ |
| TC13* | mexp_x2 | mexp=1: 0x81→2, 0x01→1 → dot=16 | ✅ Phase 8A |
| TC14* | mexp_neg1 | mexp=1: 0x7F→-1 → dot=8 | ✅ |
| TC15* | mexp1_min | mexp=1, m7=-64→-128 | ✅ 경계 |
| TC16* | nt8_step_n | NT=8 B sub-block 선택 | ✅ NT=8 전용 |

**빠진 항목:**
- LDSCALE → scale_ctx → exp_total 경로 (L4는 exp_total 직접 drive)
  → 상위 레벨(L5 이상)에서 처리
- FP 경로 (mx9_fp_mode) 단독 TC → L5 test-fpflat에서 처리

---

### L5: tb_tcu_wmma (전체 K-축적)

DUT: `VX_tcu_unit` (full K-iteration with feedback)
TC 그룹: `test-safe` / `test-sat` / `test-stream` / `test-mexp` / `test-bflat` / `test-fpflat`

| 그룹 | TC수 | 검증 내용 | 적절성 |
|------|------|---------|--------|
| test-safe | 9 | 기본 정확도 (포화 없음) | ✅ |
| test-sat | 9 | 포화 경계 (TC6_pos_sat 중심) | ✅ |
| test-stream | 9 | 파이프라인 스트리밍 (hazard) | ✅ |
| test-mexp | 6 | Phase 8A micro_exp TC | ✅ |
| test-bflat | 6 | Phase 8B block flatten TC | ✅ |
| test-fpflat | 6 | Phase 9 MX9→BF16 FP TC | ✅ |

**빠진 항목:**
- NT=4/8 동시 warp 충돌 — 단일 warp 시뮬레이션만 (K-루프 serial)
- FP path + INT path 동시 inflight (Phase 9 이중 inflight 검증 부분적)

---

### L6: tb_execute (VX_execute + VX_commit) — 현행 유지

DUT: ALU/TCU 실행 유닛 + VX_commit 중재. Phase10 FP32 기대값 사용.

| TC | 이름 | 검증 내용 | 적절성 |
|----|------|---------|--------|
| TC1 | wmma_ones_exp0 | INT8→FP32 출력 기본 동작 | ✅ Phase10 |
| TC3 | rshift_ones | FP32 exp_total 음수 스케일 | ✅ |
| TC4 | wmma_mx_style | MX 패턴 FP32 출력 | ✅ |
| TC5 | wmma_neg_accum | C=FP32(-200.0) 누산 | ✅ |
| TC6 | alu_add_basic | ALU ADD 단독 | ✅ |
| TC7 | alu_add_wrap | ALU 래핑 덧셈 | ✅ |
| TC8 | concurrent_alu_tcu | ALU+TCU 동시 dispatch + 중재 | ✅ |
| TC9 | concurrent_with_exp | 동시 dispatch + exp_total | ✅ |
| TC10 | metadata_uuid | uuid/rd 메타데이터 일치 | ✅ |

**빠진 항목:**
- LSU commit과 TCU commit 동시 충돌 우선순위 (TCU > LSU)

---

### L7: tb_issue (VX_issue 단독) — Phase 10 개편

DUT: VX_issue 단독. `dispatch_if[EX_TCU]` 직접 카운팅으로 UOP 수 검증.
Scoreboard 해제는 `inject_wb_for_tile()`로 TB가 수동 주입.

| TC | 이름 | 검증 내용 | 적절성 |
|----|------|---------|--------|
| TC1 | LDSCALE_single_dispatch | LDSCALE=1 dispatch (uop 미확장) | ✅ RTL fix |
| TC2 | WMMA_uop_dispatch | WMMA → TCU_UOPS dispatches, sop/eop 확인 | ✅ |
| TC3 | LDMICRO_dispatch | LDMICRO→1 dispatch, dispatch.wb=0 | ✅ Phase10 |
| TC4 | scoreboard_raw_stall | WMMA#1→stall WMMA#2→inject wb→WMMA#2 dispatch | ✅ 신규 |

**빠진 항목:**
- 다른 warp 간 interleaving (warp0/warp1 번갈아 dispatch)
- LDTILE_A/B/C → 1 uop dispatch 확인

---

### L8: tb_decode (VX_decode 단독) — Phase 10 개편

DUT: VX_decode 단독. `decode_if.ready=1` (TB가 항상 수락), `decode_if.data` 필드 직접 샘플링.

| TC | 이름 | 검증 내용 | 적절성 |
|----|------|---------|--------|
| TC1 | wmma_decode_fields | fmt_d=**FP32** (Phase10), tcu_op=WMMA, used_rs=111 | ✅ |
| TC2 | ldscale_decode_fields | tcu_op=LDSCALE, wb=1, used_rs=001 | ✅ |
| TC3 | ldmicro_decode_fields | tcu_op=LDMICRO=3'b011, wb=0, used_rs=011 | ✅ Phase10 |
| TC4 | alu_add_decode | ex_type=EX_ALU (헬스체크) | ✅ |

**빠진 항목:**
- LDTILE_A/B/C → tile_type 필드 추출 확인
- step_m / step_n decode (NT=8 서브블록)

---

## 4. 구현된 TB — Schedule / Fetch

### 4-1. tb_schedule (L9, ✅ 구현 완료)

**DUT**: `VX_schedule`

**목적**: warp scheduler, PC 관리, stall 제어

**입력 인터페이스:**

| 포트 | 설명 |
|------|------|
| `base_dcrs` | active_warps 초기값 등 DCR 설정 |
| `warp_ctl_if` | warp activate / deactivate (kernel launch / exit) |
| `branch_ctl_if` | branch taken/not-taken 결과 |
| `decode_sched_if` | decode 완료 통보 (ibuf_pop, wid) |
| `issue_sched_if` | issue 완료 통보 |
| `commit_sched_if` | commit 완료 통보 (warp stall 해제용) |

**출력 인터페이스:**

| 포트 | 설명 |
|------|------|
| `schedule_if.valid/ready` | fetch에게 warp 발행 |
| `schedule_if.data` | {uuid, wid, tmask, PC} |
| `busy` | kernel 실행 중 여부 |

**필요 TC:**

| TC | 이름 | 검증 포인트 |
|----|------|------------|
**경로**: `hw/rtl/tcu/tb_schedule/`
**실행**: `make` (Verilator) | `make wave` (VCD) | `make gui` (Vivado xsim WDB)

| TC | 이름 | 검증 내용 | 결과 |
|----|------|---------|------|
| TC1 | pc_sequential | warp0 연속 3회 schedule → PC +4씩 증가 | ✅ |
| TC2 | stall_no_unlock | schedule 후 stall → decode_unlock 없으면 재발행 없음 → unlock 후 재발행 | ✅ |
| TC3 | two_warp_sched | warp0/warp1 활성 → wid 번갈아 선택 (round-robin) | ✅ |
| TC4 | branch_taken | branch.taken=1 → PC = branch_dest 로 점프 | ✅ |
| TC5 | branch_not_taken | branch.taken=0 → PC 그대로 유지 | ✅ |
| TC6 | busy_signal | warp0만 활성, schedule 후 TMC로 비활성 → busy=0 | ✅ |

---

### 4-2. tb_fetch (L8b, ✅ 구현 완료)

**DUT**: `VX_fetch`

**목적**: I-cache 인터페이스, tag store, pending_ibuf

**경로**: `hw/rtl/tcu/tb_fetch/`
**실행**: `make` (Verilator) | `make wave` (VCD) | `make gui` (Vivado xsim WDB)

| TC | 이름 | 검증 내용 | 결과 |
|----|------|---------|------|
| TC1 | single_fetch | wid=0 1회 요청 → tag_store roundtrip → wid/PC/tmask/instr 정확 반환 | ✅ |
| TC2 | four_warp_tag_store | 4 warp 순차 요청 (각각 다른 PC/tmask) → 순서대로 응답 → 각 warp 데이터 불일치 없음 | ✅ |
| TC3 | interleaved_rsp | 4 warp 요청 후 역순(warp3→0) 응답 → tag_store가 wid로 올바른 {PC,tmask} 복원 | ✅ |
| TC4 | ibuf_backpressure | fetch_if.ready=0 → rsp_ready=0(5사이클 stall) → ready=1 후 instr 정상 출력 | ✅ |
| TC5 | tmask_fidelity | 3종 sparse tmask (all/single/alternating) → fetch_if.data.tmask 비트 패턴 보존 | ✅ |

---

## 5. 커버리지 요약표

| 단계 | 모듈 | L2 | L4 | L5 | L6 | L7 | L8 | L8b/L9 |
|------|------|:---:|:---:|:---:|:---:|:---:|:---:|---------|
| Schedule | VX_schedule | — | — | — | — | — | — | ✅ **tb_schedule** |
| Fetch | VX_fetch | — | — | — | — | — | — | ✅ **tb_fetch** |
| Decode | VX_decode | — | — | — | — | — | ✅ **단독** | |
| Issue | VX_issue | — | — | — | — | ✅ **단독** | — | |
| OT | operand_transformer | — | ✅ | ✅ | ✅ | — | — | |
| Execute(TCU) | VX_tcu_unit | — | ✅ | ✅ | ✅ | — | — | |
| Execute(INT) | VX_tcu_int | ✅ | ✅ | ✅ | ✅ | — | — | |
| Execute(FP) | VX_tcu_fp | — | — | ✅ | ✅ | — | — | |
| Commit | VX_commit | — | — | — | ✅ | — | — | |

---

## 6. 우선순위별 추가 TC 권고

### 단기 (기존 TB에 TC 추가)

| TB | 추가 TC | 이유 |
|----|---------|------|
| L7 tb_issue | WMMA×2 연속 → RAW stall 검증 | scoreboard 기능 미검증 |
| L7 tb_issue | LDTILE_A decode + 1 uop | LDTILE 경로 미검증 |
| L8 tb_decode | LDTILE_A/B/C decode → tile_type | tile_type 필드 미검증 |
| L8 tb_decode | step_m/step_n decode (NT=8) | sub-block 선택 미검증 |

### 중기 (신규 TB 구현) — ✅ 완료

1. **tb_schedule** (L9) ✅ — 6/6 PASS
2. **tb_fetch** (L8b) ✅ — 5/5 PASS

---

## 7. 관련 파일 경로

| 파일 | 경로 |
|------|------|
| tb_int | `hw/rtl/tcu/tb_int/tb_tcu_int.sv` |
| tb_unit | `hw/rtl/tcu/tb_unit/tb_tcu_unit.sv` |
| tb_wmma | `hw/rtl/tcu/tb_wmma/tb_tcu_wmma.sv` |
| tb_execute | `hw/rtl/tcu/tb_execute/tb_execute.sv` |
| tb_issue | `hw/rtl/tcu/tb_issue/tb_issue.sv` |
| tb_decode | `hw/rtl/tcu/tb_decode/tb_decode.sv` |
| VX_schedule | `hw/rtl/core/VX_schedule.sv` |
| VX_fetch | `hw/rtl/core/VX_fetch.sv` |
| VX_decode | `hw/rtl/core/VX_decode.sv` |
| VX_issue | `hw/rtl/core/VX_issue.sv` |
| VX_tcu_unit | `hw/rtl/tcu/VX_tcu_unit.sv` |
| VX_tcu_operand_transformer | `hw/rtl/tcu/VX_tcu_operand_transformer.sv` |
| VX_gpu_pkg (structs) | `hw/rtl/VX_gpu_pkg.sv` |

---

## 8. Waveform 분석 가이드 (tb_schedule / tb_fetch)

### 8-1. 실행 방법

#### Verilator VCD (빠른 확인 — GTKWave)

```bash
# tb_schedule
cd hw/rtl/tcu/tb_schedule
make wave          # → wave_schedule.vcd 생성
gtkwave wave_schedule.vcd &

# tb_fetch
cd hw/rtl/tcu/tb_fetch
make wave          # → wave_fetch.vcd 생성
gtkwave wave_fetch.vcd &
```

#### Vivado xsim WDB (GUI 분석)

```bash
# tb_schedule
cd hw/rtl/tcu/tb_schedule
make gui           # xvlog 컴파일 → xelab 합성 → xsim GUI 열림
                   # WDB: xsim_proj/tb_schedule_snap.wdb

# tb_fetch
cd hw/rtl/tcu/tb_fetch
make gui           # 동일 흐름
                   # WDB: xsim_proj/tb_fetch_snap.wdb
```

> **Vivado 사용법 팁**
> - `F` 또는 Zoom Fit 버튼: 전체 파형 보기
> - 마우스 휠: 수평 줌 인/아웃
> - 신호 우클릭 → Radix → Hexadecimal: hex 표시
> - File → Save Wave Config: 현재 신호 레이아웃 저장 (다음에 재사용)
> - Wave 창에서 Tcl Console 사용: `run 100 ns`, `restart` 등

**WDB만 생성하고 GUI 없이 저장**하려면 xsim_proj/tb_*_snap.wdb를 다시 열면 됨:
```bash
xsim --gui xsim_proj/tb_fetch_snap.wdb
```

---

### 8-2. tb_schedule — TC별 확인 포인트

아래 신호를 Vivado waveform에 추가해서 확인한다 (gui_xsim.tcl로 자동 추가됨).

**공통 확인 신호:**
```
clk                              — 클럭 (CLK_HALF=5ns, 주기 10ns)
reset                            — 리셋 (active high)
schedule_if/valid                — DUT가 warp를 발행하는 유효 신호
schedule_if/ready                — TB가 항상 1 (fetch 항상 수락)
schedule_if/data/wid             — 선택된 warp ID
schedule_if/data/PC              — 해당 warp의 현재 PC (byte address)
schedule_if/data/tmask           — thread mask
```

---

#### TC1: pc_sequential — "warp0 연속 스케줄 + PC +4 증가"

**무엇을 검증하나**: warp0만 활성일 때 매 사이클 wid=0으로 발행되며 PC가 4씩 증가하는지.

**파형에서 확인할 것:**

```
schedule_if/valid  ____████████████████
schedule_if/data/wid  0  0  0       (항상 wid=0)
schedule_if/data/PC   0x80000000
                        0x80000004
                          0x80000008
                            0x8000000C
```

- `schedule_if.valid && ready` 가 True인 사이클마다 PC가 0x4 씩 상승
- `tb_dec_valid && tb_dec_unlock=1` 펄스 3회가 각 schedule 사이에 오는지 확인
- 3회 발행 후 `$finish`(pass_cnt=1)

---

#### TC2: stall_no_unlock — "decode unlock 없으면 영구 stall"

**무엇을 검증하나**: schedule 1회 발행 후 warp가 stall → decode_unlock 없으면 schedule.valid=0 유지 → unlock 후 재발행.

**파형에서 확인할 것:**

```
schedule_if/valid  __█___________█__
schedule_if/data/wid  0              0
tb_dec_valid       _______████___
tb_dec_unlock      _______████___  (↑ 이 펄스 후 valid 다시 1)
```

- 첫 번째 schedule fire 이후 `valid=0` 구간이 최소 3사이클 이상
- `tb_dec_unlock` 상승 직후 다음 클럭에서 `valid=1` 재개

---

#### TC3: two_warp_sched — "round-robin wid 교대"

**무엇을 검증하나**: warp0과 warp1이 모두 활성일 때 스케줄러가 wid를 번갈아 선택.

**파형에서 확인할 것:**

```
schedule_if/data/wid  0  1  0  1  0  1  (교대 패턴)
```

- TMC(activate)로 warp1이 추가된 직후부터 wid 교대 시작
- `tb_wctl_valid`, `tb_wctl_wid` 신호로 TMC 시점 확인

---

#### TC4: branch_taken — "PC = branch destination"

**무엇을 검증하나**: branch.taken=1 → PC가 branch_dest로 점프.

**파형에서 확인할 것:**

```
schedule_if/data/PC   0x80000000  (발행 전)
tb_branch_valid        _____█_
tb_branch_taken        _____1_
tb_branch_dest         _____0xDEAD0000_
schedule_if/data/PC                0xDEAD0000  (다음 발행 시)
```

- `tb_branch_valid` 펄스 이후 schedule fire에서 PC = `tb_branch_dest`
- taken 펄스 전 PC (`0x80000000`)와 비교해서 점프했는지 확인

---

#### TC5: branch_not_taken — "PC 유지"

**무엇을 검증하나**: branch.taken=0 → PC가 변경되지 않음.

**파형에서 확인할 것:**

```
schedule_if/data/PC   0x80000000  0x80000004  (정상 증가)
tb_branch_taken        _____0_     (taken=0 — PC 유지)
```

- `tb_branch_valid` 펄스 후 PC가 `from_fullPC(0x80000000 + 4)` 그대로
- TC4와 비교해서 taken/not-taken 분기 차이 확인

---

#### TC6: busy_signal — "warp 비활성 후 busy=0"

**무엇을 검증하나**: TMC로 warp0을 비활성화하면 `busy=0`이 되는지.

**파형에서 확인할 것:**

```
busy                   1111111111100  (deactivate 후 0)
schedule_if/valid      ████████_____  (비활성 후 valid=0)
```

- schedule fire 1회 확인 후 TMC(tmask=0) 인가
- `busy` 신호가 1→0으로 전환되는 사이클 확인

---

### 8-3. tb_fetch — TC별 확인 포인트

**공통 확인 신호:**
```
clk
reset
schedule_if/valid, ready        — schedule 입력 핸드셰이크
tb_sched_wid, tb_sched_pc       — 요청 warp/PC
tb_sched_tmask                  — 요청 thread mask
icache_bus_if/req_valid         — DUT → TB icache 요청
icache_bus_if/req_data/tag      — {uuid[44b], wid[2b]} 패킹
icache_bus_if/rsp_valid, ready  — TB → DUT icache 응답
tb_icache_rsp_tag_flat          — 응답 태그 (req_data/tag 그대로 돌려줌)
tb_icache_rsp_data              — 명령어 데이터
fetch_if/valid, ready           — DUT → downstream 출력
fetch_if/data/wid               — 복원된 warp ID
fetch_if/data/PC                — tag_store에서 복원된 PC
fetch_if/data/tmask             — tag_store에서 복원된 tmask
fetch_if/data/instr             — icache에서 받은 명령어
```

---

#### TC1: single_fetch — "기본 fetch roundtrip"

**무엇을 검증하나**: schedule → icache req → icache rsp → fetch_if 까지 1 warp의 전체 흐름.

**파형에서 확인할 것:**

```
사이클 1: schedule_if valid=1, ready=1 → handshake
           req_valid=1, req_data/tag = {uuid=1, wid=0}  ← 같은 사이클에 등장

사이클 2: tb_icache_rsp_valid=1 → rsp_valid=1
           fetch_if/valid=1
           fetch_if/data: wid=0, PC=from_fullPC(0x80000010), tmask=0xF, instr=0xDEADBEEF
```

- sched fire와 req_valid가 **동일 사이클**에 나타나는 것이 핵심 (elastic buffer의 Δ-전파)
- 응답 1사이클 후 fetch_if 출력 확인

---

#### TC2: four_warp_tag_store — "warp별 tag_store 독립성"

**무엇을 검증하나**: 4개 warp 각각의 {PC, tmask}가 tag_store에서 혼동 없이 복원.

**파형에서 확인할 것:**

```
요청 단계 (4사이클):
  wid=0, PC=0x80000000, tmask=0xF → req_tag[0b00xxxxxx...00]
  wid=1, PC=0x80000100, tmask=0x3 → req_tag[0b00xxxxxx...01]
  wid=2, PC=0x80000200, tmask=0x5 → req_tag[0b00xxxxxx...10]
  wid=3, PC=0x80000300, tmask=0x1 → req_tag[0b00xxxxxx...11]

응답 단계 (4사이클):
  응답 tag=req_tag[0] → fetch: wid=0, PC=0x80000000, tmask=0xF ✓
  응답 tag=req_tag[1] → fetch: wid=1, PC=0x80000100, tmask=0x3 ✓
  ...
```

- `icache_bus_if/req_data/tag`의 하위 2비트(NW_WIDTH=2) = wid 확인
- 각 응답에서 `fetch_if/data/wid`, `PC`, `tmask`가 warp 번호와 일치하는지

---

#### TC3: interleaved_rsp — "역순 응답에서도 tag_store 정확"

**무엇을 검증하나**: 응답이 warp3→2→1→0 순으로 와도, 각 응답의 tag로 올바른 {PC, tmask} 복원.

**파형에서 확인할 것:**

```
요청 단계: wid=0→1→2→3 순서 (4사이클)
응답 단계: rsp_tag = req_tag[3], [2], [1], [0] 역순

wid=3 응답: fetch_if/data/wid=3, PC=0x800010C0, tmask=0x1 ✓
wid=2 응답: fetch_if/data/wid=2, PC=0x80001080, tmask=0x6 ✓
...
```

- `tb_icache_rsp_tag_flat` 신호값이 요청 시 캡처한 tag와 정확히 일치하는지
- 응답 순서가 달라도 `fetch_if/data/PC`가 각 warp의 올바른 PC인지

---

#### TC4: ibuf_backpressure — "fetch_ready=0 시 rsp_ready=0"

**무엇을 검증하나**: decode 측에서 backpressure(fetch_if.ready=0)를 주면 rsp_ready=0으로 I-cache 응답을 stall.

**파형에서 확인할 것:**

```
tb_fetch_ready         ████0000001   (5사이클 0, 그 후 1)
icache_bus_if/rsp_ready  ████0000001  (fetch_ready와 동일하게 움직임)
icache_bus_if/rsp_valid  ████1111111  (valid는 계속 1)

backpressure 해제 후:
fetch_if/valid=1, fetch_if/data/instr=0xFEEDFACE ✓
```

- `rsp_ready = fetch_if.ready` 경로 확인 (조합 논리 직결)
- stall_cycles ≥ 3이어야 TC PASS — 파형에서 0인 구간 카운트

---

#### TC5: tmask_fidelity — "thread mask 비트 패턴 보존"

**무엇을 검증하나**: 3종 tmask (0xF/0x1/0xA)가 tag_store에서 정확히 복원.

**파형에서 확인할 것:**

```
iter 0: tb_sched_tmask=0xF → fetch_if/data/tmask=0xF ✓
iter 1: tb_sched_tmask=0x1 → fetch_if/data/tmask=0x1 ✓
iter 2: tb_sched_tmask=0xA → fetch_if/data/tmask=0xA ✓
```

- 파형에서 `tb_sched_tmask`(입력)와 `fetch_if/data/tmask`(출력) 시간 차이 확인
- 모두 wid=0에 대해 연속 3회 → 동일 tag_store 슬롯에 덮어쓰는 패턴

---

### 8-4. 파이프라인 타이밍 요약

```
tb_schedule (VX_schedule):
  sched_valid ↑ → sched_ready ↑ → PC += 4 (next sched): 내부 elastic buffer 1cy

tb_fetch (VX_fetch):
  sched fire → req_valid=1:   동일 사이클 (elastic buffer Δ-propagation)
  rsp_valid  → fetch_if:      동일 사이클 (조합 논리 직결, tag_store async read)
```

> **Verilator vs xsim 차이 (캡처 타이밍)**
>
> Verilator `--timing` 코루틴은 `@(posedge clk iff ...)` 직후 Active region에 resume.
> 실제 registered 신호(`data_out_r`, `prev_write` 등)는 NBA 커밋 후에 반영된다.
> TB 코드에서는 이를 위해 posedge 후 `#1` 딜레이를 사용한다.
> xsim GUI에서는 표준 SV 이벤트 모델이 적용되므로, 파형에서 신호 값은 클럭 에지
> **이후** NBA가 반영된 정확한 값을 보여준다.

---

## 9. tb_pipeline 메모리 모델 (scoreboard assertion 제거)

### 9-1. 문제: preload_phase 직접 writeback injection

`tb_pipeline`은 tile 레지스터 초기값을 `preload_phase=1` 동안 `issue_wb`에 직접 주입한다:

```
TB → issue_wb 직접 inject → 레지스터 파일에 값 씀
scoreboard는 모름 → RUNTIME_ASSERT: "invalid writeback register: rd=32" 발화
```

`rd=32` = float 레지스터 f0 (`REG_TYPE_F | 5'b00000 = 6'd32`).
`RUNTIME_ASSERT`는 `$error` (비치명적)이므로 TC 결과에는 영향 없으나 xsim GUI에서 Error로 표시됨.

### 9-2. 해결: 실제 RISC-V 명령어로 프리로드

float 레지스터를 실제 명령어 3개로 초기화:

```
LUI   at, upper20(val)     → at[31:12] = upper20
ADDI  at, at, lower12(val) → at = val
FMV.W.X fd, at             → fd = float_bits(at)
```

명령어 인코딩:
```
LUI  rd, imm20:      {imm20[19:0], rd[4:0], 7'h37}
ADDI rd, rs1, imm12: {imm12[11:0], rs1[4:0], 3'b000, rd[4:0], 7'h13}
FMV.W.X fd, rs1:     {7'h78, 5'h0, rs1[4:0], 3'b000, fd[4:0], 7'h53}
```

LUI immediate 보정 (ADDI sign-extension 대응):
```
lower12 = val & 0xFFF
upper20 = val >> 12
if (lower12 >= 0x800) upper20 += 1   // ADDI가 음수로 빼므로 LUI에서 +1 보정
```

임시 정수 레지스터로 `x10 (a0)` 사용.

### 9-3. imem 자동 응답 모델

```
[변경 전] send_instr()가 instr_word를 수동으로 icache 응답에 삽입
[변경 후] imem[word_addr] 배열 + always 블록으로 자동 응답
```

```systemverilog
localparam IMEM_BASE  = 32'h8000_0000;
localparam IMEM_WORDS = 4096;
logic [31:0] imem [0:IMEM_WORDS-1];

// icache slave: 1사이클 후 자동 응답
always @(posedge clk) begin
    tb_icache_rsp_valid    <= icache_bus_if.req_valid;
    tb_icache_rsp_data     <= imem[(icache_bus_if.req_data.addr
                                    - IMEM_BASE[31:2]) & (IMEM_WORDS-1)];
    tb_icache_rsp_tag_flat <= icache_bus_if.req_data.tag;
end
assign icache_bus_if.req_ready = 1'b1;
```

### 9-4. TC 구조 변경

```
[변경 전]
preload_tile_regs(A_VAL, B_VAL, C_VAL);  // 직접 writeback inject
preload_gpr(SCALE_REG, SCALE_VAL);
preload_phase = 1'b0;
send_instr(pc, wid, tmask, INSTR_LDSCALE);

[변경 후]
// 각 float 레지스터: LUI+ADDI+FMV.W.X 3명령어 → 파이프라인 통과
for each tile reg:
    imem_write(pc, lui_instr); imem_write(pc+4, addi_instr); imem_write(pc+8, fmv_instr);
    send_instr(pc); wait_commit(); pc+=4;   // LUI
    send_instr(pc); wait_commit(); pc+=4;   // ADDI
    send_instr(pc); wait_commit(); pc+=4;   // FMV.W.X

// Scale 정수 레지스터: LUI+ADDI (FMV 불필요)
imem_write(pc, lui_instr); imem_write(pc+4, addi_instr);
send_instr(pc); wait_commit(); pc+=4;
send_instr(pc); wait_commit(); pc+=4;

// LDSCALE + WMMA 동일
imem_write(pc, INSTR_LDSCALE); send_instr(pc); wait_commit(); pc+=4;
imem_write(pc, INSTR_WMMA);    send_instr(pc); collect_wbs(UOPS, results); pc+=4;
```

`preload_phase` / `g_wb_mux` 분기 삭제 → `issue_wb[i]`를 `commit_wb[i]`에 직결.

### 9-5. 변경 파일

| 파일 | 변경 내용 |
|------|-----------|
| `tb_pipeline/tb_pipeline.sv` | imem[], icache 자동응답, load_int_reg(), load_float_reg(), preload_phase 삭제, TC 재작성 |
| `tb_pipeline/Makefile` | 변경 없음 |

### 9-6. 검증 기준

- Vivado xsim `make gui` 시 scoreboard RUNTIME_ASSERT 없음
- TC1/TC2/TC3 모두 PASS (기존과 동일 expected value)
