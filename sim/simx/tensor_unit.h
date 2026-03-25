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

#include <simobject.h>
#include "instr_trace.h"

namespace vortex {

class Core;

op_string_t op_string(TcuType tcu_type, IntrTcuArgs args);

class TensorUnit : public SimObject<TensorUnit> {
public:

  struct ExeTraceData : public ITraceData {
    using Ptr = std::shared_ptr<ExeTraceData>;
  };

	struct PerfStats {
		uint64_t latency;

		PerfStats()
			: latency(0)
		{}

		PerfStats& operator+=(const PerfStats& rhs) {
			this->latency += rhs.latency;
			return *this;
		}
	};

  std::vector<SimPort<instr_trace_t*>> Inputs;
	std::vector<SimPort<instr_trace_t*>> Outputs;

  TensorUnit(const SimContext &ctx, const char* name, const Arch& arch, Core* core);
  virtual ~TensorUnit();

  virtual void reset();

  virtual void tick();

	void wmma(uint32_t wid,
			 	    uint32_t fmt_s,
						uint32_t fmt_d,
			 	    uint32_t step_m,
						uint32_t step_n,
	          const std::vector<reg_data_t>& rs1_data,
					  const std::vector<reg_data_t>& rs2_data,
					  const std::vector<reg_data_t>& rs3_data,
					  std::vector<reg_data_t>& rd_data,
					  ExeTraceData* trace_data);

	const PerfStats& perf_stats() const;

#ifdef EXT_AG_TCU_ENABLE
  // LDSCALE: write per-warp scale context (E8M0, Phase 5)
  //   rs1_data[0][7:0]  = scale_a (8-bit E8M0 unsigned, bias=127)
  //   rs1_data[0][15:8] = scale_b (8-bit E8M0 unsigned, bias=127)
  void ldscale(uint32_t wid,
               const std::vector<reg_data_t>& rs1_data);

  // LDMICRO: write per-warp micro-exp context (Phase 10)
  //   rs1_data[t][1:0] = {pair1_mexp_a, pair0_mexp_a}  (A tile, per thread)
  //   rs2_data[t][1:0] = {pair1_mexp_b, pair0_mexp_b}  (B tile, per thread)
  void ldmicro(uint32_t wid,
               const std::vector<reg_data_t>& rs1_data,
               const std::vector<reg_data_t>& rs2_data);

  // FLAT: apply micro_exp flatten to one tile register in-place (Phase B)
  // tile_type=0 → A tile (use mexp_a), tile_type=1 → B tile (use mexp_b)
  void ldflat(uint32_t wid,
              uint32_t tile_type,
              uint32_t num_threads,
              const std::vector<reg_data_t>& rs1_data,
              std::vector<reg_data_t>& rd_data);

  // AG-WMMA: INT8 MAC + FP32 output (Phase 10: INT32→FP32 + exp_total + C(FP32))
  // fmt_s=TCU_MX9_ID: OT already flattened operands; fmt_s patched to I8_ID
  // fmt_s[3]=1 (INT): use micro_ctx flatten + FP32 output
  void ag_wmma(uint32_t wid,
               uint32_t fmt_s,
               uint32_t fmt_d,
               uint32_t step_m,
               uint32_t step_n,
               const std::vector<reg_data_t>& rs1_data,
               const std::vector<reg_data_t>& rs2_data,
               const std::vector<reg_data_t>& rs3_data,
               std::vector<reg_data_t>& rd_data,
               ExeTraceData* trace_data);

  // --- Phase 5: Block-Scaled Memory Format helper (E8M0) ---
  //
  // Represents one MX9 block in Block-Scaled memory format:
  //   scale_a_e8m0 : 8-bit E8M0 unsigned, A-matrix shared exponent (bias=127)
  //   scale_b_e8m0 : 8-bit E8M0 unsigned, B-matrix shared exponent (bias=127)
  //   mantissa     : INT8 elements (flattened: 1-bit micro-exp already applied)
  //
  // Host-side helper — used by tests to prepare ScaledBlock data before calling
  // load_scaled_operand() or ag_ldtile().
  struct ScaledBlock {
    uint8_t scale_a_e8m0;          // A-matrix E8M0 global scale (bias=127, neutral=127)
    uint8_t scale_b_e8m0;          // B-matrix E8M0 global scale (bias=127, neutral=127)
    std::vector<int8_t> mantissa;  // N flattened INT8 elements

    explicit ScaledBlock(uint32_t n_elements)
      : scale_a_e8m0(127), scale_b_e8m0(127), mantissa(n_elements, 0) {}
  };

  // load_scaled_operand(): block-scaled data → scale_ctx write + reg_data fill
  //
  // Simulates what HW Operand Transformer will eventually do transparently:
  //   1. Parse block.packed_exp → write to scale_ctx[wid]
  //   2. Pack block.mantissa[] → reg_data_t words (4 × int8 per word)
  //
  // @param wid        warp ID
  // @param block      ScaledBlock from memory (1 header byte + N mantissas)
  // @param [out] regs output reg_data_t vector (size = ceil(N/4))
  void load_scaled_operand(uint32_t wid,
                           bool is_a,     // true=scale_a, false=scale_b
                           const ScaledBlock& block,
                           std::vector<reg_data_t>& regs);
#endif

private:
	class Impl;
	Impl* impl_;
};

} // namespace vortex
