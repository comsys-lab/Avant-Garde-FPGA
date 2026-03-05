// AG-TCU Phase 5 E8M0 Verification Test
// Tests: E8M0 scale format, bidirectional shift, exp_total boundary, K-iteration
//
// Compile: g++ -std=c++17 test_ag_wmma.cpp -o test_ag_wmma
// Run:     ./test_ag_wmma
//
// Scale format: E8M0, bias=127. exp_total = scale_a + scale_b - 254 (signed).
// Shift semantics: exp>0 → left shift; exp<0 → right shift; exp=0 → no shift.
// Clamp: exp > 30 → saturate to INT32 limits; exp < -31 → flush to 0.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <climits>
#include <cassert>
#include <vector>
#include <string>

// ---------------------------------------------------------------
// AG-TCU constants (Phase 5 E8M0, matches constants.h)
// ---------------------------------------------------------------
static constexpr int32_t  AG_TCU_EXP_MAX  = 30;   // max left shift (overflow → saturate)
static constexpr int32_t  AG_TCU_EXP_MIN  = -31;  // min right shift (underflow → flush to 0)
static constexpr uint8_t  AG_TCU_EXP_BIAS = 127;  // E8M0 neutral value (both scales = 127 → exp=0)

// ---------------------------------------------------------------
// NT=8 config (matches wmma_config_t<8, int8, int32>)
// ---------------------------------------------------------------
static constexpr uint32_t NT           = 8;
static constexpr uint32_t TCM          = 4;  // tcM
static constexpr uint32_t TCN          = 2;  // tcN
static constexpr uint32_t TCK          = 2;  // tcK
static constexpr uint32_t B_SUB_BLOCKS = 2;
static constexpr uint32_t B_BLOCK_SIZE = TCK * TCN;  // 4
static constexpr uint32_t A_SUB_BLOCKS = 1;
static constexpr uint32_t A_BLOCK_SIZE = TCM * TCK;  // 8

// ---------------------------------------------------------------
// Scale Context (per-warp) — Phase 5 E8M0 format
// scale_a, scale_b: 8-bit unsigned, bias=127 (neutral=127)
// exp_total: signed, = scale_a + scale_b - 2*bias
// ---------------------------------------------------------------
struct ScaleCtx {
    uint8_t scale_a = AG_TCU_EXP_BIAS;
    uint8_t scale_b = AG_TCU_EXP_BIAS;
    int32_t exp_total() const {
        return (int32_t)scale_a + (int32_t)scale_b - 2 * (int32_t)AG_TCU_EXP_BIAS;
    }
};

// ---------------------------------------------------------------
// ag_wmma golden model (Phase 5 E8M0)
// Mirrors tensor_unit.cpp Impl::ag_wmma
// ---------------------------------------------------------------
void ag_wmma_golden(
    const ScaleCtx& ctx,
    uint32_t step_m,
    uint32_t step_n,
    const std::vector<int32_t>& rs1,    // A regs (packed INT8)
    const std::vector<int32_t>& rs2,    // B regs (packed INT8)
    const std::vector<int32_t>& rs3_in, // C (accumulators)
    std::vector<int32_t>& rd_out)       // D output
{
    int32_t  exp   = ctx.exp_total();  // signed
    uint32_t b_off = (step_n % B_SUB_BLOCKS) * B_BLOCK_SIZE;
    uint32_t a_off = (step_m % A_SUB_BLOCKS) * A_BLOCK_SIZE;

    rd_out.resize(TCM * TCN);

    for (uint32_t i = 0; i < TCM; ++i) {
        for (uint32_t j = 0; j < TCN; ++j) {
            // INT8 × INT8 MAC
            int64_t dot = 0;
            for (uint32_t k = 0; k < TCK; ++k) {
                int32_t aw = rs1[a_off + i * TCK + k];
                int32_t bw = rs2[b_off + j * TCK + k];
                for (uint32_t b = 0; b < 4; ++b) {
                    int8_t a8 = static_cast<int8_t>((aw >> (8*b)) & 0xFF);
                    int8_t b8 = static_cast<int8_t>((bw >> (8*b)) & 0xFF);
                    dot += (int64_t)a8 * (int64_t)b8;
                }
            }

            // Bidirectional shift with clamp
            int64_t aligned;
            if (exp > AG_TCU_EXP_MAX) {
                // Overflow → saturate to INT32 limits based on sign of dot
                aligned = (dot >= 0) ? (int64_t)INT32_MAX : (int64_t)INT32_MIN;
            } else if (exp < AG_TCU_EXP_MIN) {
                // Underflow → flush to 0
                aligned = 0;
            } else if (exp >= 0) {
                aligned = dot << exp;        // left shift
            } else {
                aligned = dot >> (-exp);     // arithmetic right shift
            }

            // INT32 saturation
            int32_t sat = (aligned > (int64_t)INT32_MAX) ? INT32_MAX :
                          (aligned < (int64_t)INT32_MIN) ? INT32_MIN :
                          static_cast<int32_t>(aligned);

            // Wrapping accumulate
            rd_out[i * TCN + j] = sat + rs3_in[i * TCN + j];
        }
    }
}

// ---------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------
static int pass_count = 0;
static int fail_count = 0;

void check(bool cond, const std::string& name, const std::string& detail = "") {
    if (cond) {
        printf("  [PASS] %s\n", name.c_str());
        ++pass_count;
    } else {
        printf("  [FAIL] %s%s\n", name.c_str(),
               detail.empty() ? "" : (" — " + detail).c_str());
        ++fail_count;
    }
}

// Build rs1/rs2 with all bytes = val
std::vector<int32_t> make_regs_uniform(uint32_t n_words, int8_t val) {
    uint32_t u = static_cast<uint8_t>(val);
    uint32_t word = u | (u << 8) | (u << 16) | (u << 24);
    return std::vector<int32_t>(n_words, static_cast<int32_t>(word));
}

std::vector<int32_t> make_regs_zero(uint32_t n_words) {
    return std::vector<int32_t>(n_words, 0);
}

// ---------------------------------------------------------------
// Test 1: exp_total = 0 (E8M0 neutral: scale_a=127, scale_b=127 → 127+127-254=0)
// a=1, b=1, dot=8, aligned=8<<0=8, d=8
// ---------------------------------------------------------------
void test_exp0() {
    printf("\n[Test 1] exp_total = 0 (E8M0 neutral: 127+127-254=0)\n");
    ScaleCtx ctx{127, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    // dot = 8 elements × 1×1 = 8, shift 0 → sat=8, d=8
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == 8, "d[" + std::to_string(i) + "]==8",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 2: exp_total = 1 (scale_a=128, scale_b=127 → 128+127-254=1)
// a=1, b=1, dot=8, aligned=8<<1=16, d=16
// ---------------------------------------------------------------
void test_exp1() {
    printf("\n[Test 2] exp_total = 1 (128+127-254=1, shift left 1)\n");
    ScaleCtx ctx{128, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == 16, "d[" + std::to_string(i) + "]==16",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 3: exp_total = 15 (scale_a=142, scale_b=127 → 142+127-254=15)
// a=1, b=1, dot=8, aligned=8<<15=262144
// ---------------------------------------------------------------
void test_exp15() {
    printf("\n[Test 3] exp_total = 15 (142+127-254=15, mid-range)\n");
    ScaleCtx ctx{142, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    int32_t expected = (int32_t)(8LL << 15);  // 262144
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == expected, "d[" + std::to_string(i) + "]==" + std::to_string(expected),
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 4: exp_total = 30 (scale_a=157, scale_b=127 → 157+127-254=30)
// a=1, b=1, dot=8, 8<<30=8589934592 > INT32_MAX → saturate to INT32_MAX
// ---------------------------------------------------------------
void test_exp30_saturate() {
    printf("\n[Test 4] exp_total = 30 (157+127-254=30, positive overflow → INT32_MAX)\n");
    ScaleCtx ctx{157, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    // dot=8, 8<<30 = 8589934592 > INT32_MAX → sat = INT32_MAX
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == INT32_MAX, "d[" + std::to_string(i) + "]==INT32_MAX",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 5: exp_total = 31 > EXP_MAX=30 (overflow clamp, first out-of-range value)
// scale_a=158, scale_b=127 → 158+127-254=31 > 30
// dot=8, clamped → INT32_MAX (positive dot)
// ---------------------------------------------------------------
void test_exp31_overflow() {
    printf("\n[Test 5] exp_total = 31 > EXP_MAX=30 (158+127-254=31, overflow clamp)\n");
    ScaleCtx ctx{158, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == INT32_MAX, "d[" + std::to_string(i) + "]==INT32_MAX (overflow)",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 6: Negative dot, exp_total=30 → INT32_MIN
// a=-1, b=1, each pair: (-1)(1)=-1 × 8 pairs → dot=-8
// (-8)<<30 = -8589934592 < INT32_MIN → saturate to INT32_MIN
// ---------------------------------------------------------------
void test_clamp_negative_dot() {
    printf("\n[Test 6] Negative dot: exp_total=30, dot=-8 → INT32_MIN (157+127-254=30)\n");
    ScaleCtx ctx{157, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, -1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == INT32_MIN, "d[" + std::to_string(i) + "]==INT32_MIN",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 7: Overflow clamp, positive dot (exp=32 > 30)
// scale_a=159, scale_b=127 → 159+127-254=32 > 30, dot=8 → INT32_MAX
// ---------------------------------------------------------------
void test_clamp_guard_positive() {
    printf("\n[Test 7] Clamp guard: exp_total=32 > 30, dot=8 → INT32_MAX (159+127-254=32)\n");
    ScaleCtx ctx{159, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == INT32_MAX, "d[" + std::to_string(i) + "]==INT32_MAX (clamp)",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 8: Overflow clamp, negative dot (exp=32 > 30)
// scale_a=159, scale_b=127 → 159+127-254=32 > 30, dot=-8 → INT32_MIN
// ---------------------------------------------------------------
void test_clamp_guard_negative() {
    printf("\n[Test 8] Clamp guard: exp_total=32 > 30, dot=-8 → INT32_MIN (159+127-254=32)\n");
    ScaleCtx ctx{159, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, -1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == INT32_MIN, "d[" + std::to_string(i) + "]==INT32_MIN (clamp)",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 9: K-iteration tile-level exp constraint
// K-loop 3회 실행, exp_total=2 고정 (scale 불변) → accumulate
// scale_a=129, scale_b=127 → 129+127-254=2
// uop0: d = 8<<2 + 0 = 32
// uop1: d = 8<<2 + 32 = 64
// uop2: d = 8<<2 + 64 = 96
// ---------------------------------------------------------------
void test_k_iteration_constraint() {
    printf("\n[Test 9] K-iteration tile-level exp constraint (129+127-254=2)\n");
    ScaleCtx ctx{129, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);

    auto rs3_0 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd0;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3_0, rd0);
    // dot=8, 8<<2=32, d=32
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd0[i] == 32, "K=0: d[" + std::to_string(i) + "]==32",
              "got " + std::to_string(rd0[i]));

    std::vector<int32_t> rd1;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rd0, rd1);
    // dot=8, 8<<2=32, d=32+32=64
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd1[i] == 64, "K=1: d[" + std::to_string(i) + "]==64",
              "got " + std::to_string(rd1[i]));

    std::vector<int32_t> rd2;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rd1, rd2);
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd2[i] == 96, "K=2: d[" + std::to_string(i) + "]==96",
              "got " + std::to_string(rd2[i]));
}

// ---------------------------------------------------------------
// Test 10: K-iteration exp CHANGE (constraint VIOLATION)
// exp_total changes mid-K → documents incorrect result
// K=0: exp=2 (129+127-254=2), dot=8 → d0=32
// K=1: exp=0 (127+127-254=0) → d1 = 8+32=40  (mathematically wrong, correct=64)
// ---------------------------------------------------------------
void test_k_exp_change_violation() {
    printf("\n[Test 10] K-iteration exp change mid-K (documents violation)\n");
    ScaleCtx ctx0{129, 127};  // exp=2
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3_0 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd0;
    ag_wmma_golden(ctx0, 0, 0, rs1, rs2, rs3_0, rd0);

    // K=1: exp changes to 0 → d1 = 8<<0 + 32 = 40 (mathematically WRONG)
    // Correct would be: (8+8)<<2 = 64
    ScaleCtx ctx1{127, 127};  // exp=0
    std::vector<int32_t> rd1;
    ag_wmma_golden(ctx1, 0, 0, rs1, rs2, rd0, rd1);
    printf("    K=0 result (exp=2): d[0]=%d (correct=32)\n", rd0[0]);
    printf("    K=1 result (exp=0): d[0]=%d (mathematically wrong, correct=64)\n", rd1[0]);
    check(rd1[0] != 64, "exp change → wrong result (expected violation)",
          "d[0]=" + std::to_string(rd1[0]) + " != 64");
    printf("    [INFO] AG-TCU requires same exp across K-iterations (tile-level constraint)\n");
}

// ---------------------------------------------------------------
// Test 11: Wrapping accumulator (c near INT32_MAX + small value)
// sat + c wraps without secondary saturation
// exp=0 (neutral), dot=8, sat=8, c=INT32_MAX-4 → d wraps to INT32_MIN+3
// ---------------------------------------------------------------
void test_wrapping_accumulator() {
    printf("\n[Test 11] Wrapping accumulator (no secondary saturation, 127+127-254=0)\n");
    ScaleCtx ctx{127, 127};  // exp=0
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    std::vector<int32_t> rs3(TCM * TCN, INT32_MAX - 4);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    // sat=8, c=INT32_MAX-4: wrapping: 8 + (INT32_MAX-4) = INT32_MIN+3
    int32_t expected = static_cast<int32_t>(
        static_cast<uint32_t>(8) + static_cast<uint32_t>(INT32_MAX - 4));
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == expected, "d[" + std::to_string(i) + "] wraps to " + std::to_string(expected),
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 12: B sub-block offset (step_n routing)
// step_n=0 → b_off=0 (block bytes=1, dot=8), step_n=1 → b_off=4 (block bytes=2, dot=16)
// ---------------------------------------------------------------
void test_b_sub_block_routing() {
    printf("\n[Test 12] B sub-block offset: step_n=0 vs step_n=1 (127+127-254=0)\n");
    ScaleCtx ctx{127, 127};  // exp=0
    std::vector<int32_t> rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    std::vector<int32_t> rs2(B_BLOCK_SIZE * B_SUB_BLOCKS, 0);
    // block 0 (b_off=0): bytes = 1
    for (int w = 0; w < (int)B_BLOCK_SIZE; w++) rs2[w] = 0x01010101;
    // block 1 (b_off=4): bytes = 2
    for (int w = 0; w < (int)B_BLOCK_SIZE; w++) rs2[B_BLOCK_SIZE + w] = 0x02020202;

    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd0, rd1;

    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd0);  // step_n=0 → b_off=0, b=1, dot=8
    ag_wmma_golden(ctx, 0, 1, rs1, rs2, rs3, rd1);  // step_n=1 → b_off=4, b=2, dot=16

    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd0[i] == 8,  "step_n=0: d[" + std::to_string(i) + "]==8",  "got " + std::to_string(rd0[i]));
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd1[i] == 16, "step_n=1: d[" + std::to_string(i) + "]==16", "got " + std::to_string(rd1[i]));
}

// ---------------------------------------------------------------
// Test 13: E8M0 right shift (negative exp)
// scale_a=126, scale_b=127 → 126+127-254=-1 → right shift 1
// a=1, b=1, dot=8, 8>>1=4, d=4
// ---------------------------------------------------------------
void test_e8m0_right_shift() {
    printf("\n[Test 13] E8M0 right shift: exp=-1 (126+127-254=-1), dot=8 → d=4\n");
    ScaleCtx ctx{126, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    // dot=8, 8>>1=4
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == 4, "d[" + std::to_string(i) + "]==4",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 14: E8M0 right shift boundary (exp = EXP_MIN = -31)
// scale_a=96, scale_b=127 → 96+127-254=-31 → right shift 31
// a=1, b=1, dot=8, 8>>31=0 (positive value, drops out of 31-bit range)
// ---------------------------------------------------------------
void test_e8m0_right_shift_boundary() {
    printf("\n[Test 14] E8M0 right shift boundary: exp=-31 (96+127-254=-31), dot=8 → d=0\n");
    ScaleCtx ctx{96, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    // dot=8, 8>>31=0 (last valid right shift before underflow)
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == 0, "d[" + std::to_string(i) + "]==0 (>>31=0)",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// Test 15: E8M0 underflow flush (exp < EXP_MIN = -31 → flush to 0)
// scale_a=95, scale_b=127 → 95+127-254=-32 < -31 → flush
// dot=8, aligned=0, d=0
// ---------------------------------------------------------------
void test_e8m0_underflow_flush() {
    printf("\n[Test 15] E8M0 underflow flush: exp=-32 < EXP_MIN=-31 (95+127-254=-32), dot=8 → d=0\n");
    ScaleCtx ctx{95, 127};
    auto rs1 = make_regs_uniform(A_BLOCK_SIZE, 1);
    auto rs2 = make_regs_uniform(B_BLOCK_SIZE * B_SUB_BLOCKS, 1);
    auto rs3 = make_regs_zero(TCM * TCN);
    std::vector<int32_t> rd;
    ag_wmma_golden(ctx, 0, 0, rs1, rs2, rs3, rd);
    // exp < EXP_MIN → flush to 0
    for (uint32_t i = 0; i < TCM * TCN; ++i)
        check(rd[i] == 0, "d[" + std::to_string(i) + "]==0 (underflow flush)",
              "got " + std::to_string(rd[i]));
}

// ---------------------------------------------------------------
// main
// ---------------------------------------------------------------
int main() {
    printf("=== AG-TCU Phase 5 E8M0 Verification Test ===\n");
    printf("NT=%u, tcM=%u, tcN=%u, tcK=%u, b_sub_blocks=%u\n",
           NT, TCM, TCN, TCK, B_SUB_BLOCKS);
    printf("E8M0: bias=%u, EXP_MAX=%d, EXP_MIN=%d\n",
           AG_TCU_EXP_BIAS, AG_TCU_EXP_MAX, AG_TCU_EXP_MIN);

    test_exp0();
    test_exp1();
    test_exp15();
    test_exp30_saturate();
    test_exp31_overflow();
    test_clamp_negative_dot();
    test_clamp_guard_positive();
    test_clamp_guard_negative();
    test_k_iteration_constraint();
    test_k_exp_change_violation();
    test_wrapping_accumulator();
    test_b_sub_block_routing();
    test_e8m0_right_shift();
    test_e8m0_right_shift_boundary();
    test_e8m0_underflow_flush();

    printf("\n=== Results: %d passed, %d failed ===\n", pass_count, fail_count);
    return (fail_count == 0) ? 0 : 1;
}
