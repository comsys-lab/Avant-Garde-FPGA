#include <iostream>
#include <unistd.h>
#include <string.h>
#include <vector>
#include <chrono>
#include <vortex.h>
#include <cmath>
#include "common.h"

#define FLOAT_ULP 6

#define RT_CHECK(_expr)                                         \
   do {                                                         \
     int _ret = _expr;                                          \
     if (0 == _ret)                                             \
       break;                                                   \
     printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);   \
	 cleanup();			                                              \
     exit(-1);                                                  \
   } while (false)

///////////////////////////////////////////////////////////////////////////////

template <typename Type>
class Comparator {};

template <>
class Comparator<int> {
public:
  static const char* type_str() {
    return "integer";
  }
  static int generate() {
    return rand();
  }
  static bool compare(int a, int b, int index, int errors) {
    if (a != b) {
      if (errors < 100) {
        printf("*** error: [%d] expected=%d, actual=%d\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<float> {
public:
  static const char* type_str() {
    return "float";
  }
  static float generate() {
    return static_cast<float>(rand()) / RAND_MAX;
  }
  static bool compare(float a, float b, int index, int errors) {
    union fi_t { float f; int32_t i; };
    fi_t fa, fb;
    fa.f = a;
    fb.f = b;
    auto d = std::abs(fa.i - fb.i);
    if (d > FLOAT_ULP) {
      if (errors < 100) {
        printf("*** error: [%d] expected=%f, actual=%f\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

// CPU reference: sparse matrix A (CSR) * dense matrix B -> C
// A: m x k (sparse, CSR format)
// B: k x n (dense)
// C: m x n (dense output)
static void spmm_cpu(TYPE* C, 
                     const TYPE* A_val, 
                     const uint32_t* A_col, 
                     const uint32_t* A_row_ptr,
                     const TYPE* B,
                     uint32_t m, uint32_t n, uint32_t k) {
  for (uint32_t i = 0; i < m; ++i) {
    for (uint32_t j = 0; j < n; ++j) {
      TYPE sum = TYPE(0);
      for (uint32_t idx = A_row_ptr[i]; idx < A_row_ptr[i + 1]; ++idx) {
        uint32_t col = A_col[idx];
        if (col < k) {
          sum += A_val[idx] * B[col * n + j];
        }
      }
      C[i * n + j] = sum;
    }
  }
}

const char* kernel_file = "kernel.vxbin";
uint32_t m = 32;  // rows of sparse matrix
uint32_t n = 32;  // cols of dense matrix B
uint32_t k = 32;  // cols of sparse matrix (rows of B)
float sparsity = 0.9f;  // 90% sparse (10% non-zero)

vx_device_h device = nullptr;
vx_buffer_h A_val_buffer = nullptr;
vx_buffer_h A_col_buffer = nullptr;
vx_buffer_h A_row_ptr_buffer = nullptr;
vx_buffer_h B_buffer = nullptr;
vx_buffer_h C_buffer = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
kernel_arg_t kernel_arg = {};

static void show_usage() {
   std::cout << "Vortex Sparse Matrix Multiplication Test." << std::endl;
   std::cout << "Usage: [-k: kernel] [-m rows] [-n cols] [-s sparsity] [-h: help]" << std::endl;
}

static void parse_args(int argc, char **argv) {
  int c;
  while ((c = getopt(argc, argv, "m:n:s:k:h")) != -1) {
    switch (c) {
    case 'm':
      m = atoi(optarg);
      break;
    case 'n':
      n = atoi(optarg);
      break;
    case 's':
      sparsity = atof(optarg);
      break;
    case 'k':
      kernel_file = optarg;
      break;
    case 'h':
      show_usage();
      exit(0);
      break;
    default:
      show_usage();
      exit(-1);
    }
  }
}

void cleanup() {
  if (device) {
    vx_mem_free(A_val_buffer);
    vx_mem_free(A_col_buffer);
    vx_mem_free(A_row_ptr_buffer);
    vx_mem_free(B_buffer);
    vx_mem_free(C_buffer);
    vx_mem_free(krnl_buffer);
    vx_mem_free(args_buffer);
    vx_dev_close(device);
  }
}

int main(int argc, char *argv[]) {
  // parse command arguments
  parse_args(argc, argv);

  std::srand(50);

  // open device connection
  std::cout << "open device connection" << std::endl;
  RT_CHECK(vx_dev_open(&device));

  uint32_t k_fixed = k;  // use fixed k value
  uint32_t B_size = k_fixed * n * sizeof(TYPE);
  uint32_t C_size = m * n * sizeof(TYPE);

  std::cout << "data type: " << Comparator<TYPE>::type_str() << std::endl;
  std::cout << "matrix sizes: A(" << m << "x" << k_fixed << "), B(" << k_fixed << "x" << n << "), C(" << m << "x" << n << ")" << std::endl;
  std::cout << "sparsity: " << (sparsity * 100.0f) << "%" << std::endl;

  kernel_arg.grid_dim[0] = n;
  kernel_arg.grid_dim[1] = m;
  kernel_arg.m = m;
  kernel_arg.n = n;
  kernel_arg.k = k_fixed;

  // Generate sparse matrix A in CSR format
  std::vector<TYPE> h_A_val;
  std::vector<uint32_t> h_A_col;
  std::vector<uint32_t> h_A_row_ptr(m + 1, 0);
  
  for (uint32_t i = 0; i < m; ++i) {
    for (uint32_t j = 0; j < k_fixed; ++j) {
      float rand_val = static_cast<float>(rand()) / RAND_MAX;
      if (rand_val > sparsity) {
        // Add non-zero element
        h_A_val.push_back(Comparator<TYPE>::generate());
        h_A_col.push_back(j);
      }
    }
    h_A_row_ptr[i + 1] = h_A_val.size();
  }

  uint32_t nnz = h_A_val.size();
  uint32_t A_val_size = nnz * sizeof(TYPE);
  uint32_t A_col_size = nnz * sizeof(uint32_t);
  uint32_t A_row_ptr_size = (m + 1) * sizeof(uint32_t);

  std::cout << "nnz: " << nnz << " (" << (100.0f * nnz / (m * k_fixed)) << "%)" << std::endl;

  kernel_arg.nnz = nnz;

  // allocate device memory
  std::cout << "allocate device memory" << std::endl;
  RT_CHECK(vx_mem_alloc(device, A_val_size, VX_MEM_READ, &A_val_buffer));
  RT_CHECK(vx_mem_address(A_val_buffer, &kernel_arg.A_val_addr));
  RT_CHECK(vx_mem_alloc(device, A_col_size, VX_MEM_READ, &A_col_buffer));
  RT_CHECK(vx_mem_address(A_col_buffer, &kernel_arg.A_col_addr));
  RT_CHECK(vx_mem_alloc(device, A_row_ptr_size, VX_MEM_READ, &A_row_ptr_buffer));
  RT_CHECK(vx_mem_address(A_row_ptr_buffer, &kernel_arg.A_row_ptr_addr));
  RT_CHECK(vx_mem_alloc(device, B_size, VX_MEM_READ, &B_buffer));
  RT_CHECK(vx_mem_address(B_buffer, &kernel_arg.B_addr));
  RT_CHECK(vx_mem_alloc(device, C_size, VX_MEM_WRITE, &C_buffer));
  RT_CHECK(vx_mem_address(C_buffer, &kernel_arg.C_addr));

  std::cout << "A_val_addr=0x" << std::hex << kernel_arg.A_val_addr << std::endl;
  std::cout << "A_col_addr=0x" << std::hex << kernel_arg.A_col_addr << std::endl;
  std::cout << "A_row_ptr_addr=0x" << std::hex << kernel_arg.A_row_ptr_addr << std::endl;
  std::cout << "B_addr=0x" << std::hex << kernel_arg.B_addr << std::endl;
  std::cout << "C_addr=0x" << std::hex << kernel_arg.C_addr << std::dec << std::endl;

  // generate dense matrix B
  std::vector<TYPE> h_B(k_fixed * n);
  for (uint32_t i = 0; i < k_fixed * n; ++i) {
    h_B[i] = Comparator<TYPE>::generate();
  }

  // upload sparse matrix A (CSR format)
  {
    std::cout << "upload sparse matrix A (values)" << std::endl;
    RT_CHECK(vx_copy_to_dev(A_val_buffer, h_A_val.data(), 0, A_val_size));
    
    std::cout << "upload sparse matrix A (column indices)" << std::endl;
    RT_CHECK(vx_copy_to_dev(A_col_buffer, h_A_col.data(), 0, A_col_size));
    
    std::cout << "upload sparse matrix A (row pointers)" << std::endl;
    RT_CHECK(vx_copy_to_dev(A_row_ptr_buffer, h_A_row_ptr.data(), 0, A_row_ptr_size));
  }

  // upload matrix B buffer
  {
    std::cout << "upload matrix B buffer" << std::endl;
    RT_CHECK(vx_copy_to_dev(B_buffer, h_B.data(), 0, B_size));
  }

  // Upload kernel binary
  std::cout << "Upload kernel binary" << std::endl;
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  // upload kernel argument
  std::cout << "upload kernel argument" << std::endl;
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));

  auto time_start = std::chrono::high_resolution_clock::now();

  // start device
  std::cout << "start device" << std::endl;
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));

  // wait for completion
  std::cout << "wait for completion" << std::endl;
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  auto time_end = std::chrono::high_resolution_clock::now();
  double elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(time_end - time_start).count();
  printf("Elapsed time: %lg ms\n", elapsed);

  // download destination buffer
  std::cout << "download destination buffer" << std::endl;
  std::vector<TYPE> h_C(m * n);
  RT_CHECK(vx_copy_from_dev(h_C.data(), C_buffer, 0, C_size));

  // verify result
  std::cout << "verify result" << std::endl;
  int errors = 0;
  {
    std::vector<TYPE> h_ref(m * n);
    spmm_cpu(h_ref.data(), h_A_val.data(), h_A_col.data(), h_A_row_ptr.data(),
             h_B.data(), m, n, k_fixed);

    for (uint32_t i = 0; i < h_ref.size(); ++i) {
      if (!Comparator<TYPE>::compare(h_C[i], h_ref[i], i, errors)) {
        ++errors;
      }
    }
  }

  // cleanup
  std::cout << "cleanup" << std::endl;
  cleanup();

  if (errors != 0) {
    std::cout << "Found " << std::dec << errors << " errors!" << std::endl;
    std::cout << "FAILED!" << std::endl;
    return errors;
  }

  std::cout << "PASSED!" << std::endl;

  return 0;
}
