#include <stdio.h>
#include <vx_intrinsics.h>
#include <vx_print.h>
#include <vx_spawn.h>

////////////////////////////////////////////////////////////////////////////////
// Very Simple Malloc implementation (modified vecadd)

#define HEAP_SZ 1024 * 1024

char __data_pool[HEAP_SZ];  // pool
int __data_pool_offset = 0; // Tracks how much memory has been used

void *vx_malloc(int sz) {
  if (__data_pool_offset + sz > HEAP_SZ) {
    vx_printf("Out of memory\n");
    return nullptr;
  }

  void *ptr = &__data_pool[__data_pool_offset];
  __data_pool_offset += sz;
  return ptr;
}

void vx_free(void *ptr) {
  // Do nothing (for now)
}

////////////////////////////////////////////////////////////////////////////////
// Kernel

typedef struct {
  int *A; // M x K
  int *B; // K x N
  int *C; // M x N
  int M;
  int N;
  int K;
} matmul_args_t;

// Each thread computes one element C[row, col]
void matmul_kernel(matmul_args_t *__UNIFORM__ args) {
  int tid = blockIdx.x; // use blockIdx.x as thread index (same as vecadd)
  int M = args->M;
  int N = args->N;
  int K = args->K;

  int row = tid / N;
  int col = tid % N;

  if (row >= M || col >= N) return;

  int sum = 0;
  for (int k = 0; k < K; k++) {
    int a = args->A[row * K + k];
    int b = args->B[k * N + col];
    sum += a * b;
  }
  args->C[row * N + col] = sum;
  vx_printf("[+] thread %d -> C[%d,%d] = %d\n", tid, row, col, sum);
}

////////////////////////////////////////////////////////////////////////////////
// Host code

int main() {
  vx_printf(">> Starting matmul host part (coreid=%d, warpid=%d, threadid=%d)\n",
            vx_core_id(), vx_warp_id(), vx_thread_id());

  vx_printf(">> Malloc Pool address: %p\n", __data_pool);
  vx_printf(">> Malloc Pool size: %d\n", HEAP_SZ);

  vx_printf(">> Allocating matrices\n");
  int M = 4;
  int K = 4;
  int N = 4;

  int *A = (int *)vx_malloc(M * K * sizeof(int));
  int *B = (int *)vx_malloc(K * N * sizeof(int));
  int *C = (int *)vx_malloc(M * N * sizeof(int));

  // Initialize A and B
  for (int i = 0; i < M; i++) {
    for (int j = 0; j < K; j++) {
      A[i * K + j] = i * 10 + j; // simple pattern
    }
  }
  for (int i = 0; i < K; i++) {
    for (int j = 0; j < N; j++) {
      B[i * N + j] = i * 5 + j; // simple pattern
    }
  }

  vx_printf(">> A matrix:\n");
  for (int i = 0; i < M; i++) {
    for (int j = 0; j < K; j++) {
      vx_printf("%3d ", A[i * K + j]);
    }
    vx_printf("\n");
  }

  vx_printf(">> B matrix:\n");
  for (int i = 0; i < K; i++) {
    for (int j = 0; j < N; j++) {
      vx_printf("%3d ", B[i * N + j]);
    }
    vx_printf("\n");
  }

  matmul_args_t args;
  args.A = A;
  args.B = B;
  args.C = C;
  args.M = M;
  args.N = N;
  args.K = K;

  vx_printf(">> Launching kernel: computing %d x %d output (%d threads)\n", M, N, M * N);
  uint32_t total_threads = M * N;
  vx_spawn_threads(1, &total_threads, nullptr, (vx_kernel_func_cb)matmul_kernel, &args);

  vx_printf(">> Kernel finished executing\n");

  vx_printf(">> Result C matrix:\n");
  int error = 0;
  for (int i = 0; i < M; i++) {
    for (int j = 0; j < N; j++) {
      int val = C[i * N + j];
      vx_printf("%5d ", val);
    }
    vx_printf("\n");
  }

  // Verify against CPU reference
  for (int i = 0; i < M; i++) {
    for (int j = 0; j < N; j++) {
      int ref = 0;
      for (int k = 0; k < K; k++) {
        ref += A[i * K + k] * B[k * N + j];
      }
      if (ref != C[i * N + j]) {
        error = 1;
        vx_printf("Mismatch at [%d,%d]: got %d expected %d\n", i, j, C[i * N + j], ref);
      }
    }
  }

  if (!error) {
    vx_printf("*** Matmul completed successfully! ***\n");
  } else {
    vx_printf("*** Matmul failed verification! ***\n");
  }

  return 0;
}
