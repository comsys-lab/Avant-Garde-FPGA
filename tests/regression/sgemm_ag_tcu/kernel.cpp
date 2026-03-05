#include "common.h"
#include <vx_spawn.h>
#include <vx_tensor.h>
#include <vx_intrinsics.h>

namespace vt = vortex::tensor;
using ctx = vt::wmma_context<NUM_THREADS, vt::ITYPE, vt::OTYPE>;

// AG-TCU LDSCALE intrinsic
//
// Issues LDSCALE to write the per-warp E8M0 scale context.
// Encoding: opcode=CUSTOM0(0x0B), funct3=0, funct7=6(=3'b110)
//   rs1 = packed {scale_b[7:0], scale_a[7:0]}  (16 high bits ignored)
//   rd  = x0 (no integer writeback; result goes to scale_ctx[wid])
//
// exp_total = scale_a + scale_b - 254  (signed, range [-254, +256])
//   Neutral:  scale_a=scale_b=127 → exp_total=0  (no shift)
//   Positive: scale_a=129,scale_b=127 → exp_total=+2 (left shift 2)
//   Negative: scale_a=126,scale_b=127 → exp_total=-1 (right shift 1)
#ifdef EXT_AG_TCU_ENABLE
__attribute__((always_inline))
static inline void vx_ldscale(uint8_t scale_a, uint8_t scale_b) {
  uint32_t packed = ((uint32_t)scale_b << 8) | (uint32_t)scale_a;
  __asm__ volatile (
    ".insn r %0, 0, 6, x0, %1, x0"
    :: "i"(RISCV_CUSTOM0), "r"(packed)
  );
}
#endif

void kernel_body(kernel_arg_t *__UNIFORM__ arg) {
  auto pA = reinterpret_cast<ctx::input_t *>(arg->A_addr);
  auto pB = reinterpret_cast<ctx::input_t *>(arg->B_addr);
  auto pC = reinterpret_cast<ctx::output_t *>(arg->C_addr);

  uint32_t M = arg->M;
  uint32_t N = arg->N;
  uint32_t K = arg->K;

  ctx::fragment_a   fragA;
  ctx::fragment_b   fragB;
  ctx::fragment_acc fragC;

  uint32_t tile_row = blockIdx.y * ctx::tileM;
  uint32_t tile_col = blockIdx.x * ctx::tileN;

  // Initialize accumulator to zero
  ctx::fill_fragment(fragC, 0);

  // Issue LDSCALE once per output tile (before the K-loop).
  // Sets warp-local E8M0 scale context used by all subsequent WMMA uops.
#ifdef EXT_AG_TCU_ENABLE
  vx_ldscale(arg->scale_a, arg->scale_b);
#endif

  // K-loop: accumulate over tileK-sized chunks
  for (int i = 0; i < (int)K; i += ctx::tileK) {
    // Load A tile (row-major)
    auto pTileA = pA + tile_row * K + i;
    ctx::load_matrix_sync(fragA, pTileA, K);

    // Load B tile (row-major, int8 only)
    auto pTileB = pB + i * N + tile_col;
    ctx::load_matrix_sync(fragB, pTileB, N);

    // Matrix multiply-accumulate: fragC += fragA * fragB
    // Hardware reads scale_ctx[wid] and applies E8M0 shift to each micro-tile dot.
    ctx::mma_sync(fragC, fragA, fragB, fragC);
  }

  // Store result
  auto pTileC = pC + tile_row * N + tile_col;
  ctx::store_matrix_sync(pTileC, fragC, N);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(2, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_body, arg);
}
