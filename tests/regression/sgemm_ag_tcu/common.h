#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#ifndef NUM_THREADS
#define NUM_THREADS 4
#endif

#ifndef ITYPE
#define ITYPE int8
#endif

#ifndef OTYPE
#define OTYPE int32
#endif

typedef struct {
  uint32_t grid_dim[2];
  uint32_t block_dim[2];
  uint32_t M, N, K;
  uint64_t A_addr;
  uint64_t B_addr;
  uint64_t C_addr;
  uint8_t  scale_a;   // E8M0 A-matrix scale (unsigned, bias=127, neutral=127)
  uint8_t  scale_b;   // E8M0 B-matrix scale (unsigned, bias=127, neutral=127)
} kernel_arg_t;

#endif
