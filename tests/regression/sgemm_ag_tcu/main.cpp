#include "common.h"
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <vector>
#include <tensor_cfg.h>
#include <vortex.h>

#define MAX_ERRORS 10

#define RT_CHECK(_expr)                                        \
  do {                                                         \
    int _ret = _expr;                                          \
    if (0 != _ret) {                                           \
      printf("Error: '%s' returned %d!\n", #_expr, _ret);     \
      cleanup();                                               \
      exit(-1);                                                \
    }                                                          \
  } while (false)

using cfg = vortex::tensor::wmma_config_t<NUM_THREADS,
                                          vortex::tensor::int8,
                                          vortex::tensor::int32>;

static const char *kernel_file = "kernel.vxbin";

static uint32_t xm       = 32;
static uint32_t xn       = 32;
static uint32_t xk       = 32;
static uint8_t  g_scale_a = 127;  // E8M0 neutral (exp_total = 0)
static uint8_t  g_scale_b = 127;

static vx_device_h device      = nullptr;
static vx_buffer_h A_buffer    = nullptr;
static vx_buffer_h B_buffer    = nullptr;
static vx_buffer_h C_buffer    = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;
static kernel_arg_t kernel_arg = {};

///////////////////////////////////////////////////////////////////////////////

static void show_usage() {
  printf("Vortex AG-TCU SGEMM Test (INT8 → INT32, E8M0 scale)\n");
  printf("Usage: [-m M] [-n N] [-k K] [-a scale_a] [-b scale_b] [-h]\n");
  printf("  scale_a, scale_b : E8M0 unsigned [0, 255], neutral = 127\n");
  printf("  exp_total = scale_a + scale_b - 254   (signed, clamped to [-31, 30])\n");
}

static void parse_args(int argc, char **argv) {
  int c;
  while ((c = getopt(argc, argv, "m:n:k:a:b:h")) != -1) {
    switch (c) {
    case 'm': xm       = (uint32_t)atoi(optarg); break;
    case 'n': xn       = (uint32_t)atoi(optarg); break;
    case 'k': xk       = (uint32_t)atoi(optarg); break;
    case 'a': g_scale_a = (uint8_t)atoi(optarg); break;
    case 'b': g_scale_b = (uint8_t)atoi(optarg); break;
    case 'h': show_usage(); exit(0);
    default:  show_usage(); exit(-1);
    }
  }
}

static void cleanup() {
  if (device) {
    vx_mem_free(A_buffer);
    vx_mem_free(B_buffer);
    vx_mem_free(C_buffer);
    vx_mem_free(krnl_buffer);
    vx_mem_free(args_buffer);
    vx_dev_close(device);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Reference: E8M0-scaled INT8 matrix multiply
//
// Matches hardware FEDP granularity: scale is applied per micro-tile of depth
// cfg::tcK (not to the total per-element dot product).  For left shift (exp≥0)
// both models are equivalent (shift distributes over addition).  For right
// shift (exp<0), floor-division does NOT distribute, so we must iterate in
// cfg::tcK chunks and accumulate shifted partial sums.
//
// D[m][n] = saturate( Σ_{k step tcK} apply_exp(Σ_{j<tcK} A[m][k+j]*B[k+j][n]) )
///////////////////////////////////////////////////////////////////////////////
static void ag_matmul_ref(int32_t *C, const int8_t *A, const int8_t *B,
                           uint32_t M, uint32_t N, uint32_t K,
                           uint8_t scale_a, uint8_t scale_b) {
  const int32_t exp = (int32_t)scale_a + (int32_t)scale_b - 254;

  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t n = 0; n < N; ++n) {
      int64_t acc = 0;
      // Each FEDP processes tcK 32-bit words × i_ratio INT8 elements/word.
      // Iterate in that granularity to match hardware floor-division semantics.
      const uint32_t step = cfg::tcK * cfg::i_ratio;
      for (uint32_t k = 0; k < K; k += step) {
        int32_t dot = 0;
        for (uint32_t j = 0; j < step; ++j)
          dot += (int32_t)A[m * K + k + j] * (int32_t)B[(k + j) * N + n];

        int64_t shifted;
        if      (exp > 30)   shifted = (dot >= 0) ? (int64_t)INT32_MAX : (int64_t)INT32_MIN;
        else if (exp < -31)  shifted = 0;
        else if (exp >= 0)   shifted = (int64_t)dot << exp;
        else                 shifted = (int64_t)dot >> (-exp);  // arithmetic right shift

        acc += shifted;
      }

      int64_t sat = (acc > INT32_MAX) ? INT32_MAX :
                    (acc < INT32_MIN) ? INT32_MIN : acc;
      C[m * N + n] = (int32_t)sat;
    }
  }
}

///////////////////////////////////////////////////////////////////////////////

int main(int argc, char *argv[]) {
  parse_args(argc, argv);

  const int32_t exp_total = (int32_t)g_scale_a + (int32_t)g_scale_b - 254;
  printf("AG-TCU SGEMM: M=%u N=%u K=%u | scale_a=%u scale_b=%u exp_total=%d\n",
         xm, xn, xk, g_scale_a, g_scale_b, exp_total);

  // Open device connection
  printf("open device connection\n");
  RT_CHECK(vx_dev_open(&device));

  // Check TCU extension support
  uint64_t isa_flags;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_ISA_FLAGS, &isa_flags));
  if (!(isa_flags & VX_ISA_EXT_TCU)) {
    printf("Error: TCU extension not supported by this build!\n");
    printf("  Rebuild simx with: CONFIGS=\"-DEXT_TCU_ENABLE -DEXT_AG_TCU_ENABLE\"\n");
    cleanup();
    return -1;
  }

  // Verify warp size matches kernel compilation
  uint64_t NT;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &NT));
  if (NT != NUM_THREADS) {
    printf("Error: device warp size (%lu) != NUM_THREADS=%d\n", NT, NUM_THREADS);
    cleanup();
    return -1;
  }

  // Validate matrix dimensions are multiples of tile dimensions
  if ((xm % cfg::tileM) || (xn % cfg::tileN) || (xk % cfg::tileK)) {
    printf("Error: M/N/K must be multiples of tileM=%u / tileN=%u / tileK=%u\n",
           cfg::tileM, cfg::tileN, cfg::tileK);
    cleanup();
    return -1;
  }

  printf("WMMA core  : M=%u N=%u K=%u\n", cfg::tcM, cfg::tcN, cfg::tcK);
  printf("WMMA tile  : M=%u N=%u K=%u\n", cfg::tileM, cfg::tileN, cfg::tileK);

  const size_t sizeA = xm * xk;
  const size_t sizeB = xk * xn;
  const size_t sizeC = xm * xn;

  // Allocate device memory
  printf("allocate device memory\n");
  RT_CHECK(vx_mem_alloc(device, sizeA * sizeof(int8_t),  VX_MEM_READ,  &A_buffer));
  RT_CHECK(vx_mem_address(A_buffer, &kernel_arg.A_addr));
  RT_CHECK(vx_mem_alloc(device, sizeB * sizeof(int8_t),  VX_MEM_READ,  &B_buffer));
  RT_CHECK(vx_mem_address(B_buffer, &kernel_arg.B_addr));
  RT_CHECK(vx_mem_alloc(device, sizeC * sizeof(int32_t), VX_MEM_WRITE, &C_buffer));
  RT_CHECK(vx_mem_address(C_buffer, &kernel_arg.C_addr));

  // Generate test data.
  // Use small values [-4, 4] so per-step saturation cannot occur even for
  // non-neutral scale, making the simplified reference exact.
  //   max_dot_per_elem = K * 4 * 4 = 16K → for K=32: 512
  //   max shifted (exp=30): 512 << 30 ≈ 5e11 > INT32_MAX → saturation possible
  //   For exp ≤ ~21 and K=32: 512 << 21 ≈ 1e9 < INT32_MAX → safe
  std::srand(42);
  std::vector<int8_t> h_A(sizeA), h_B(sizeB);
  for (auto &v : h_A) v = (int8_t)((rand() % 9) - 4);  // [-4, 4]
  for (auto &v : h_B) v = (int8_t)((rand() % 9) - 4);

  // Upload operands
  printf("upload matrix A\n");
  RT_CHECK(vx_copy_to_dev(A_buffer, h_A.data(), 0, sizeA * sizeof(int8_t)));
  printf("upload matrix B\n");
  RT_CHECK(vx_copy_to_dev(B_buffer, h_B.data(), 0, sizeB * sizeof(int8_t)));

  // Set kernel arguments
  kernel_arg.grid_dim[0]  = xn / cfg::tileN;
  kernel_arg.grid_dim[1]  = xm / cfg::tileM;
  kernel_arg.block_dim[0] = (uint32_t)NT;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.M            = xm;
  kernel_arg.N            = xn;
  kernel_arg.K            = xk;
  kernel_arg.scale_a      = g_scale_a;
  kernel_arg.scale_b      = g_scale_b;

  // Upload kernel and argument struct
  printf("upload kernel\n");
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg), &args_buffer));

  // Launch kernel
  printf("start device\n");
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));

  printf("wait for completion\n");
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  // Download result
  std::vector<int32_t> h_C(sizeC);
  printf("download result\n");
  RT_CHECK(vx_copy_from_dev(h_C.data(), C_buffer, 0, sizeC * sizeof(int32_t)));

  // Compute CPU reference and verify
  std::vector<int32_t> h_ref(sizeC);
  ag_matmul_ref(h_ref.data(), h_A.data(), h_B.data(), xm, xn, xk,
                g_scale_a, g_scale_b);

  printf("verify result\n");
  int errors = 0;
  for (uint32_t i = 0; i < (uint32_t)sizeC; ++i) {
    if (h_C[i] != h_ref[i]) {
      if (errors < MAX_ERRORS)
        printf("*** error[%u]: got=0x%08x (%d), expected=0x%08x (%d)\n",
               i, (uint32_t)h_C[i], h_C[i], (uint32_t)h_ref[i], h_ref[i]);
      ++errors;
    }
  }

  cleanup();

  if (errors) {
    printf("FAILED! (%d / %zu errors)\n", errors, sizeC);
    return errors;
  }

  printf("PASSED!\n");
  return 0;
}
