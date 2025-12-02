#ifndef _COMMON_H_
#define _COMMON_H_

#ifndef TYPE
#define TYPE float
#endif

typedef struct {
  uint32_t grid_dim[2];
  uint32_t m;        // rows of sparse matrix A
  uint32_t n;        // cols of dense matrix B (and output C)
  uint32_t k;        // cols of sparse matrix A (rows of B)
  uint32_t nnz;      // number of non-zeros in A
  uint64_t A_val_addr;     // sparse matrix A values
  uint64_t A_col_addr;     // sparse matrix A column indices
  uint64_t A_row_ptr_addr; // sparse matrix A row pointers (CSR format)
  uint64_t B_addr;   // dense matrix B (k x n)
  uint64_t C_addr;   // output matrix C (m x n)
} kernel_arg_t;

#endif
