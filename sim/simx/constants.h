// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

#include <VX_config.h>
#include <bitmanip.h>

#ifndef RAM_PAGE_SIZE
#define RAM_PAGE_SIZE     4096
#endif

#ifndef MEM_CLOCK_RATIO
#define MEM_CLOCK_RATIO   1
#endif

namespace vortex {

inline constexpr uint32_t XLENB           = (XLEN / 8);
inline constexpr uint32_t VLENB           = (VLEN / 8);

inline constexpr uint32_t MAX_NUM_CORES   = 1024;
inline constexpr uint32_t MAX_NUM_WARPS   = 64;
inline constexpr uint32_t MAX_NUM_REGS    = 32;
inline constexpr uint32_t LOG_NUM_REGS    = 5;
inline constexpr uint32_t NUM_SRC_REGS    = 3;

inline constexpr uint32_t LSU_WORD_SIZE   = (XLEN / 8);
inline constexpr uint32_t LSU_CHANNELS    = NUM_LSU_LANES;
inline constexpr uint32_t LSU_NUM_REQS	  = (NUM_LSU_BLOCKS * LSU_CHANNELS);

// The dcache uses coalesced memory blocks
inline constexpr uint32_t DCACHE_WORD_SIZE= LSU_LINE_SIZE;
inline constexpr uint32_t DCACHE_CHANNELS = UP((NUM_LSU_LANES * XLENB) / DCACHE_WORD_SIZE);
inline constexpr uint32_t DCACHE_NUM_REQS	= (NUM_LSU_BLOCKS * DCACHE_CHANNELS);

inline constexpr uint32_t NUM_SOCKETS     = UP(NUM_CORES / SOCKET_SIZE);

inline constexpr uint32_t L2_NUM_REQS     = NUM_SOCKETS * L1_MEM_PORTS;
inline constexpr uint32_t L3_NUM_REQS     = NUM_CLUSTERS * L2_MEM_PORTS;

inline constexpr uint32_t PER_ISSUE_WARPS = NUM_WARPS / ISSUE_WIDTH;
inline constexpr uint32_t ISSUE_WIS_BITS  = log2ceil(PER_ISSUE_WARPS);

#ifdef EXT_AG_TCU_ENABLE
// AG-TCU: Scale Context Register (per-warp, 2-port)
// Matches VX_tcu_pkg.sv: TCU_EXP_BITS=8, TCU_EXP_BIAS=127, TCU_EXP_TOTAL=10
// Phase 5: E8M0 format — scale_a/scale_b are unsigned 8-bit [0,255]; bias=127.
//   exp_total = scale_a + scale_b - 2*bias; range [-254, +256], clamped to [-31, +30].
inline constexpr uint32_t AG_TCU_EXP_BITS  = 8;    // bits per side (unsigned E8M0: 0..255)
inline constexpr uint32_t AG_TCU_EXP_BIAS  = 127;  // E8M0 bias (neutral: scale=127 → exp_total=0)
inline constexpr uint32_t AG_TCU_EXP_TOTAL = 10;   // signed sum width (covers [-254, +256])
inline constexpr int32_t  AG_TCU_EXP_MAX   = 30;   // left shift clamp (early saturation)
inline constexpr int32_t  AG_TCU_EXP_MIN   = -31;  // right shift flush-to-zero bound

// Tile / TC dimensions are NUM_THREADS-dependent; derived in tensor_unit.cpp via wmma_config_t.
// Shift: exp_total >= 0 → left shift; exp_total < 0 → arithmetic right shift.
// Clamp: exp_total > AG_TCU_EXP_MAX → early saturation; exp_total < AG_TCU_EXP_MIN → flush to 0.
#endif

} // namespace vortex
