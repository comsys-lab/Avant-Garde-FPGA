#include <vx_spawn.h>
#include "common.h"

void kernel_body(kernel_arg_t* __UNIFORM__ arg) {
	auto A_val = reinterpret_cast<TYPE*>(arg->A_val_addr);
	auto A_col = reinterpret_cast<uint32_t*>(arg->A_col_addr);
	auto A_row_ptr = reinterpret_cast<uint32_t*>(arg->A_row_ptr_addr);
	auto B = reinterpret_cast<TYPE*>(arg->B_addr);
	auto C = reinterpret_cast<TYPE*>(arg->C_addr);
	
	uint32_t m = arg->m;
	uint32_t n = arg->n;
	uint32_t k = arg->k;

	int col = blockIdx.x;
	int row = blockIdx.y;

	// Check bounds
	if (row >= m || col >= n) return;

	// Compute C[row, col] using CSR format of A
	// C[row, col] = sum over all non-zero elements in row of A
	TYPE sum = TYPE(0);
	for (uint32_t i = A_row_ptr[row]; i < A_row_ptr[row + 1]; ++i) {
		uint32_t a_col = A_col[i];
		if (a_col < k) {
			TYPE a_val = A_val[i];
			TYPE b_val = B[a_col * n + col];
			sum += a_val * b_val;
		}
	}

	C[row * n + col] = sum;
}

int main() {
	kernel_arg_t* arg = (kernel_arg_t*)csr_read(VX_CSR_MSCRATCH);
	return vx_spawn_threads(2, arg->grid_dim, nullptr, (vx_kernel_func_cb)kernel_body, arg);
}
