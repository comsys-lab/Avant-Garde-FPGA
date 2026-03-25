
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

#include "tensor_unit.h"
#include "tensor_cfg.h"
#include <rvfloats.h>
#include "core.h"
#include <cstring>

using namespace vortex;

namespace vt = vortex::tensor;
using cfg = vt::wmma_config_t<NUM_THREADS>;

#ifdef EXT_AG_TCU_ENABLE
// Scale Context Register: per-warp, 2-port (scale_a / scale_b)
// Matches VX_tcu_scale_ctx.sv
// Phase 5: E8M0 unsigned 8-bit [0,255]; bias=127; exp_total = a + b - 2*bias.
struct ScaleContext {
  std::vector<uint8_t> scale_a;  // E8M0 unsigned: 0..255 (bias=127 → neutral)
  std::vector<uint8_t> scale_b;
  explicit ScaleContext(uint32_t num_warps)
    : scale_a(num_warps, AG_TCU_EXP_BIAS), scale_b(num_warps, AG_TCU_EXP_BIAS) {}
  void write(uint32_t wid, uint8_t sa, uint8_t sb) {
    scale_a[wid] = sa;
    scale_b[wid] = sb;
  }
  int32_t exp_total(uint32_t wid) const {
    return (int32_t)scale_a[wid] + (int32_t)scale_b[wid]
         - 2 * (int32_t)AG_TCU_EXP_BIAS; // [-254, +256], clamped later
  }
};

// Micro-Exp Context Register: per-warp, per-thread, pair-shared micro-exp bits
// Matches VX_tcu_micro_ctx.sv (Phase 10)
// mexp_a[wid][t][1:0] = {pair1_mexp_a, pair0_mexp_a} for A tile, thread t
// mexp_b[wid][t][1:0] = {pair1_mexp_b, pair0_mexp_b} for B tile, thread t
struct MicroExpContext {
  // [warp][thread][pair0=bit0, pair1=bit1]
  std::vector<std::vector<uint8_t>> mexp_a;  // 2 bits per thread
  std::vector<std::vector<uint8_t>> mexp_b;
  explicit MicroExpContext(uint32_t num_warps, uint32_t num_threads)
    : mexp_a(num_warps, std::vector<uint8_t>(num_threads, 0))
    , mexp_b(num_warps, std::vector<uint8_t>(num_threads, 0)) {}
  void write(uint32_t wid, const std::vector<uint8_t>& ma, const std::vector<uint8_t>& mb) {
    mexp_a[wid] = ma;
    mexp_b[wid] = mb;
  }
  uint8_t get_a(uint32_t wid, uint32_t t) const { return mexp_a[wid][t] & 0x3; }
  uint8_t get_b(uint32_t wid, uint32_t t) const { return mexp_b[wid][t] & 0x3; }
};

// INT8 flatten with saturation: flat = saturate_int8(int8_val << mexp_bit)
static int8_t flatten_int8_byte(int8_t v, uint8_t mexp) {
  if (mexp == 0) return v;
  int16_t shifted = static_cast<int16_t>(v) << 1;
  if (shifted >  127) return  127;
  if (shifted < -128) return -128;
  return static_cast<int8_t>(shifted);
}
#endif

inline uint64_t nan_box(uint32_t value) {
  return value | 0xffffffff00000000;
}

template <typename It, typename Ot>
struct FMA {
  using itype = typename It::dtype;
  using otype = typename Ot::dtype;
  static otype eval(itype a, itype b, otype c) {
    return static_cast<otype>(a) * static_cast<otype>(b) + c;
  }
};

template <>
struct FMA<vt::fp16, vt::fp32> {
  static float eval(uint16_t a, uint16_t b, float c) {
    auto xa = rv_htof_s(a, 0, nullptr);
    auto xb = rv_htof_s(b, 0, nullptr);
    auto xab= rv_fmul_s(xa, xb, 0, nullptr);
    auto xc = bit_cast<uint32_t>(c);
    auto xd = rv_fadd_s(xab, xc, 0, nullptr);
    return bit_cast<float>(xd);
  }
};

template <>
struct FMA<vt::fp16, vt::fp16> {
  static uint16_t eval(uint16_t a, uint16_t b, uint16_t c) {
    auto xa = rv_htof_s(a, 0, nullptr);
    auto xb = rv_htof_s(b, 0, nullptr);
    auto xc = rv_htof_s(c, 0, nullptr);
    auto xd = rv_fmadd_s(xa, xb, xc, 0, nullptr);
    auto xh = rv_ftoh_s(xd, 0, nullptr);
    return xh;
  }
};

template <>
struct FMA<vt::bf16, vt::fp32> {
  static float eval(uint16_t a, uint16_t b, float c) {
    auto xa = rv_btof_s(a, 0, nullptr);
    auto xb = rv_btof_s(b, 0, nullptr);
    auto xab= rv_fmul_s(xa, xb, 0, nullptr);
    auto xc = bit_cast<uint32_t>(c);
    auto xd = rv_fadd_s(xab, xc, 0, nullptr);
    return bit_cast<float>(xd);
  }
};

template <>
struct FMA<vt::bf16, vt::bf16> {
  static uint16_t eval(uint16_t a, uint16_t b, uint16_t c) {
    auto xa = rv_btof_s(a, 0, nullptr);
    auto xb = rv_btof_s(b, 0, nullptr);
    auto xc = rv_btof_s(c, 0, nullptr);
    auto xd = rv_fmadd_s(xa, xb, xc, 0, nullptr);
    auto xh = rv_ftob_s(xd, 0, nullptr);
    return xh;
  }
};

template <typename It, typename Ot>
struct FEDP {
  using itype = typename It::dtype;
  using otype = typename Ot::dtype;
  static uint32_t eval(const reg_data_t *a_row, const reg_data_t *b_col, uint32_t c_val) {
  constexpr uint32_t i_ratio = sizeof(uint32_t) / sizeof(itype);
  static_assert(i_ratio * sizeof(itype) == sizeof(uint32_t), "FEDP: tcK * i_ratio must be <= 32");
  auto acc = bit_cast<otype>(c_val);
  for (uint32_t z = 0; z < cfg::tcK; ++z) {
    auto a = reinterpret_cast<const itype *>(&a_row[z].u32);
    auto b = reinterpret_cast<const itype *>(&b_col[z].u32);
    for (uint32_t i = 0; i < i_ratio; ++i) {
      acc = FMA<It, Ot>::eval(a[i], b[i], acc);
    }
  }
  return bit_cast<uint32_t>(acc);
  }
};

template <>
struct FEDP<vt::int4, vt::int32>{
  static uint32_t eval(const reg_data_t *a_row, const reg_data_t *b_col, uint32_t c_val) {
    auto acc = bit_cast<int32_t>(c_val);
    for (uint32_t z = 0; z < cfg::tcK; ++z) {
      auto a = a_row[z].u32;
      auto b = b_col[z].u32;
      for (uint32_t i = 0; i < 8; ++i) { // 8 * 4 bits = 32 bits
        int32_t a_val = (a >> (i * 4)) & 0xF;
        int32_t b_val = (b >> (i * 4)) & 0xF;
        if (a_val & 0x8) {
          a_val |= 0xFFFFFFF0;
        }
        if (b_val & 0x8) {
          b_val |= 0xFFFFFFF0;
        }
        acc += a_val * b_val;
      }
    }
    return bit_cast<uint32_t>(acc);
  }
};

template <>
struct FEDP<vt::uint4, vt::int32>{
  static uint32_t eval(const reg_data_t *a_row, const reg_data_t *b_col, uint32_t c_val) {
    auto acc = bit_cast<int32_t>(c_val);
    for (uint32_t z = 0; z < cfg::tcK; ++z) {
      auto a = a_row[z].u32;
      auto b = b_col[z].u32;
      for (uint32_t i = 0; i < 8; ++i) { // 8 * 4 bits = 32 bits
        int32_t a_val = (a >> (i * 4)) & 0xF;
        int32_t b_val = (b >> (i * 4)) & 0xF;
        acc += a_val * b_val;
      }
    }
    return bit_cast<uint32_t>(acc);
  }
};

using PFN_FEDP = uint32_t (*)(const reg_data_t*, const reg_data_t*, uint32_t);

static PFN_FEDP select_FEDP(uint32_t IT, uint32_t OT) {
  switch (OT) {
  case vt::fp32::id:
    switch (IT) {
    case vt::fp16::id:
      return FEDP<vt::fp16, vt::fp32>::eval;
    case vt::bf16::id:
      return FEDP<vt::bf16, vt::fp32>::eval;
    default:
      std::cout << "Error: unsupported mma format: " << IT << " -> " << OT << "!" << std::endl;
      std::abort();
    }
    break;
  case vt::fp16::id:
    switch (IT) {
    case vt::fp16::id:
      return FEDP<vt::fp16, vt::fp16>::eval;
    default:
      std::cout << "Error: unsupported mma format: " << IT << " -> " << OT << "!" << std::endl;
      std::abort();
    }
    break;
  case vt::bf16::id:
    switch (IT) {
    case vt::bf16::id:
      return FEDP<vt::bf16, vt::bf16>::eval;
    default:
      std::cout << "Error: unsupported mma format: " << IT << " -> " << OT << "!" << std::endl;
      std::abort();
    }
    break;
  case vt::int32::id:
    switch (IT) {
    case vt::int8::id:
      return FEDP<vt::int8, vt::int32>::eval;
    case vt::uint8::id:
      return FEDP<vt::uint8, vt::int32>::eval;
    case vt::int4::id:
      return FEDP<vt::int4, vt::int32>::eval;
    case vt::uint4::id:
      return FEDP<vt::uint4, vt::int32>::eval;
    default:
      std::cout << "Error: unsupported mma format: " << IT << " -> " << OT << "!" << std::endl;
      std::abort();
    }
    break;
  default:
    std::cout << "Error: unsupported output type: " << OT << "!" << std::endl;
    std::abort();
  }
}

class TensorUnit::Impl {
public:
  Impl(TensorUnit* simobject, const Arch& arch, Core* core)
    : simobject_(simobject)
    , core_(core)
    , arch_(arch)
    , perf_stats_()
#ifdef EXT_AG_TCU_ENABLE
    , scale_ctx_(arch.num_warps())
    , micro_ctx_(arch.num_warps(), arch.num_threads())
#endif
  {
    //--
  }

  ~Impl() {
    // Destructor logic if needed
  }

  void reset() {
    perf_stats_ = PerfStats();
  }

  void tick() {
    for (uint32_t iw = 0; iw < ISSUE_WIDTH; ++iw) {
      auto& input = simobject_->Inputs.at(iw);
      if (input.empty())
        continue;
      auto trace = input.front();
      auto tcu_type = std::get<TcuType>(trace->op_type);
      int delay = 0;
      switch (tcu_type) {
      case TcuType::WMMA:
        delay = 4;
        break;
#ifdef EXT_AG_TCU_ENABLE
      case TcuType::LDSCALE:
        delay = 1;  // single-cycle context write
        break;
      case TcuType::LDTILE:
        delay = 1;  // single-cycle tile register load
        break;
      case TcuType::LDMICRO:
        delay = 1;  // single-cycle micro_ctx write
        break;
      case TcuType::FLAT:
        delay = 1;  // single-cycle flatten (FEDP bypass)
        break;
#endif
      default:
        std::abort();
      }
      simobject_->Outputs.at(iw).push(trace, 2 + delay);
      DT(3, simobject_->name() << ": op=" << tcu_type << ", " << *trace);
      input.pop();
    }
  }

  void wmma(uint32_t wid,
            uint32_t fmt_s,
            uint32_t fmt_d,
            uint32_t step_m,
            uint32_t step_n,
            const std::vector<reg_data_t>& rs1_data,
            const std::vector<reg_data_t>& rs2_data,
            const std::vector<reg_data_t>& rs3_data,
            std::vector<reg_data_t>& rd_data,
            ExeTraceData* trace_data) {
    __unused(wid);
    __unused(trace_data);

    auto fedp = select_FEDP(fmt_s, fmt_d);

    uint32_t a_off = (step_m % cfg::a_sub_blocks) * cfg::a_block_size;
    uint32_t b_off = (step_n % cfg::b_sub_blocks) * cfg::b_block_size;

    for (uint32_t i = 0; i < cfg::tcM; ++i) {
      for (uint32_t j = 0; j < cfg::tcN; ++j) {
        auto a_row = rs1_data.data() + a_off + i * cfg::tcK;
        auto b_col = rs2_data.data() + b_off + j * cfg::tcK;
        auto c_val = rs3_data.at(i * cfg::tcN + j).u32;
        auto d_val = fedp(a_row, b_col, c_val);
        rd_data.at(i * cfg::tcN + j).u64 = nan_box(d_val);

        DTH(3, "FEDP: wid=" << wid << ", i=" << i << ", j=" << j << ", m=" << step_m << ", n=" << step_n << ", a_row={" << std::hex);
        for (uint32_t q = 0; q < cfg::tcK; ++q) {
          if (q) DTN(3, ", ");
          DTN(3, "0x" << a_row[q].u32);
        }
        DTN(3, "}, b_col={");
        for (uint32_t q = 0; q < cfg::tcK; ++q) {
          if (q) DTN(3, ", ");
          DTN(3, "0x" << b_col[q].u32);
        }
        DTN(3, "}, c_val=0x" << c_val << ", d_val=0x" << d_val << std::dec << std::endl);
      }
    }
  }

  const PerfStats& perf_stats() const {
    return perf_stats_;
  }

#ifdef EXT_AG_TCU_ENABLE
  void ldscale(uint32_t wid, const std::vector<reg_data_t>& rs1_data) {
    // Phase 5 E8M0 packing: rs1_data[0][7:0] = scale_a, [15:8] = scale_b (unsigned 8-bit)
    uint32_t word = rs1_data.at(0).u32;
    uint8_t sa = (word >> 0) & 0xFF;
    uint8_t sb = (word >> 8) & 0xFF;
    scale_ctx_.write(wid, sa, sb);
    DTH(3, "LDSCALE: wid=" << wid << ", scale_a=" << (unsigned)sa << ", scale_b=" << (unsigned)sb << std::endl);
  }

  void ldmicro(uint32_t wid,
               const std::vector<reg_data_t>& rs1_data,
               const std::vector<reg_data_t>& rs2_data) {
    // Phase 10: rs1_data[t][1:0] = {pair1_mexp_a, pair0_mexp_a}
    //           rs2_data[t][1:0] = {pair1_mexp_b, pair0_mexp_b}
    uint32_t num_threads = static_cast<uint32_t>(rs1_data.size());
    std::vector<uint8_t> ma(num_threads), mb(num_threads);
    for (uint32_t t = 0; t < num_threads; ++t) {
      ma[t] = rs1_data.at(t).u32 & 0x3;
      mb[t] = rs2_data.at(t).u32 & 0x3;
    }
    micro_ctx_.write(wid, ma, mb);
    DTH(3, "LDMICRO: wid=" << wid
        << ", mexp_a[0]=0x" << std::hex << (unsigned)ma[0]
        << ", mexp_b[0]=0x" << (unsigned)mb[0] << std::dec << std::endl);
  }

  // Phase B: FLAT — apply micro_exp flatten to one tile register in-place.
  // tile_type=0 → A tile (use mexp_a), tile_type=1 → B tile (use mexp_b).
  void ldflat(uint32_t wid,
              uint32_t tile_type,
              uint32_t num_threads,
              const std::vector<reg_data_t>& rs1_data,
              std::vector<reg_data_t>& rd_data) {
    rd_data.resize(num_threads);
    for (uint32_t t = 0; t < num_threads; ++t) {
      uint32_t word = rs1_data.at(t).u32;
      // mexp packed: [2*MEXP_BITS-1:MEXP_BITS]=pair1, [MEXP_BITS-1:0]=pair0 (MEXP_BITS=1)
      uint8_t mexp = (tile_type == 0) ? micro_ctx_.get_a(wid, t) : micro_ctx_.get_b(wid, t);
      uint8_t mexp_p0 = (mexp >> 0) & 0x1;  // pair0 (bytes 0,1)
      uint8_t mexp_p1 = (mexp >> 1) & 0x1;  // pair1 (bytes 2,3)
      uint32_t flat = 0;
      for (uint32_t b = 0; b < 4; ++b) {
        uint8_t raw = (word >> (8 * b)) & 0xFF;
        uint8_t mp  = (b < 2) ? mexp_p0 : mexp_p1;
        int8_t  fi  = flatten_int8_byte(static_cast<int8_t>(raw), mp);
        flat |= (static_cast<uint32_t>(static_cast<uint8_t>(fi)) << (8 * b));
      }
      rd_data[t].u32 = flat;
    }
    DTH(3, "FLAT: wid=" << wid << ", tile_type=" << tile_type
        << ", rd[0]=0x" << std::hex << rd_data[0].u32 << std::dec << std::endl);
  }

  void ag_wmma(uint32_t wid,
               uint32_t fmt_s,
               uint32_t fmt_d,
               uint32_t step_m,
               uint32_t step_n,
               const std::vector<reg_data_t>& rs1_data,
               const std::vector<reg_data_t>& rs2_data,
               const std::vector<reg_data_t>& rs3_data,
               std::vector<reg_data_t>& rd_data,
               ExeTraceData* trace_data) {
    __unused(trace_data);
    __unused(fmt_d);
    __unused(fmt_s);

    int32_t exp_total = scale_ctx_.exp_total(wid);

    // B/A sub-block offsets (matches RTL)
    uint32_t b_off = (step_n % cfg::b_sub_blocks) * cfg::b_block_size;
    uint32_t a_off = (step_m % cfg::a_sub_blocks) * cfg::a_block_size;

    // -----------------------------------------------------------------------
    // Phase 10 INT path:
    //   OT flattens INT8 using micro_ctx: flat = saturate(INT8 << mexp)
    //   FEDP: INT32 dot product → FP32 (CLZ) → exp_total adjust → FP32 + C(FP32)
    // -----------------------------------------------------------------------
    for (uint32_t i = 0; i < cfg::tcM; ++i) {
      for (uint32_t j = 0; j < cfg::tcN; ++j) {
        int32_t dot = 0;
        for (uint32_t k = 0; k < cfg::tcK; ++k) {
          uint32_t t_idx = a_off + i * cfg::tcK + k;  // thread index for A
          uint32_t aw    = rs1_data.at(t_idx).u32;
          uint32_t bw    = rs2_data.at(b_off + j * cfg::tcK + k).u32;

          // Get micro_exp for this thread's word
          uint8_t mexp_a = micro_ctx_.get_a(wid, t_idx);  // {pair1,pair0}
          uint8_t mexp_b = micro_ctx_.get_b(wid, t_idx);

          for (uint32_t b = 0; b < 4; ++b) {
            uint8_t a_raw  = (aw >> (8 * b)) & 0xFF;
            uint8_t b_raw  = (bw >> (8 * b)) & 0xFF;
            // pair0 = bytes 0,1 (b<2), pair1 = bytes 2,3 (b>=2)
            uint8_t pair_idx = (b >= 2) ? 1 : 0;
            uint8_t ma_bit = (mexp_a >> pair_idx) & 0x1;
            uint8_t mb_bit = (mexp_b >> pair_idx) & 0x1;
            int8_t  a8 = flatten_int8_byte(static_cast<int8_t>(a_raw), ma_bit);
            int8_t  b8 = flatten_int8_byte(static_cast<int8_t>(b_raw), mb_bit);
            dot += static_cast<int32_t>(a8) * static_cast<int32_t>(b8);
          }
        }

        // INT32 → FP32 (exact for |dot| < 2^24) + exp_total adjust
        float fp_dot = std::ldexp(static_cast<float>(dot), exp_total);

        // FP32 + C(FP32) accumulation
        float c    = bit_cast<float>(rs3_data.at(i * cfg::tcN + j).u32);
        float d    = fp_dot + c;
        uint32_t d_bits = bit_cast<uint32_t>(d);
        rd_data.at(i * cfg::tcN + j).u64 = nan_box(d_bits);

        DTH(3, "AG-FEDP(int10): wid=" << wid << ", i=" << i << ", j=" << j
            << ", m=" << step_m << ", n=" << step_n
            << ", exp_total=" << exp_total
            << ", dot=" << dot << ", fp_dot=" << fp_dot
            << ", d=0x" << std::hex << d_bits << std::dec << std::endl);
      }
    }
  }
#endif

#ifdef EXT_AG_TCU_ENABLE
  // Phase 5: load_scaled_operand_impl()
  // Host-side helper: ScaledBlock (E8M0 format) -> scale_ctx write + reg_data fill
  //   1. block.scale_a_e8m0 / scale_b_e8m0 -> scale_ctx[wid]
  //   2. mantissa[] (int8_t, already flattened) -> packed reg_data_t words (4 bytes/word)
  void load_scaled_operand_impl(uint32_t wid,
                                bool is_a,
                                const TensorUnit::ScaledBlock& block,
                                std::vector<reg_data_t>& regs) {
    // Step 1: write exponent to Scale Context (E8M0)
    if (is_a) {
      scale_ctx_.write(wid, block.scale_a_e8m0, scale_ctx_.scale_b[wid]);
    } else {
      scale_ctx_.write(wid, scale_ctx_.scale_a[wid], block.scale_b_e8m0);
    }
    DTH(3, "load_scaled_operand: wid=" << wid
        << ", is_a=" << is_a
        << ", scale_a=" << (int)scale_ctx_.scale_a[wid]
        << ", scale_b=" << (int)scale_ctx_.scale_b[wid] << std::endl);

    // Step 2: pack mantissa int8_t[] into reg_data_t word array (4 bytes per word)
    const uint32_t n = (uint32_t)block.mantissa.size();
    const uint32_t n_words = (n + 3) / 4;
    regs.resize(n_words);
    for (uint32_t w = 0; w < n_words; ++w) {
      uint32_t packed = 0;
      for (uint32_t b = 0; b < 4; ++b) {
        uint32_t idx = w * 4 + b;
        uint8_t byte = (idx < n) ? static_cast<uint8_t>(block.mantissa[idx]) : 0;
        packed |= (uint32_t)byte << (8 * b);
      }
      regs[w].u32 = packed;
    }
  }
#endif

private:

  TensorUnit*   simobject_;
  Core*         core_;
  Arch          arch_;
  PerfStats     perf_stats_;
#ifdef EXT_AG_TCU_ENABLE
  ScaleContext    scale_ctx_;
  MicroExpContext micro_ctx_;
#endif
};

///////////////////////////////////////////////////////////////////////////////

op_string_t vortex::op_string(TcuType tcu_type, IntrTcuArgs args) {
  switch (tcu_type) {
  case TcuType::WMMA:
    return {"WMMA." + std::string(vt::fmt_string(args.fmt_s)) + "." + std::string(vt::fmt_string(args.fmt_d))
             + "." + std::to_string(args.step_m) + "." + std::to_string(args.step_n), ""};
#ifdef EXT_AG_TCU_ENABLE
  case TcuType::LDSCALE:
    return {"LDSCALE", ""};
  case TcuType::LDTILE:
    return {"LDTILE." + std::to_string(args.tile_type), ""};
  case TcuType::LDMICRO:
    return {"LDMICRO", ""};
  case TcuType::FLAT:
    return {"FLAT." + std::to_string(args.tile_type), ""};
#endif
  default:
    std::abort();
  }
}

///////////////////////////////////////////////////////////////////////////////

TensorUnit::TensorUnit(const SimContext &ctx, const char* name, const Arch& arch, Core* core)
	: SimObject<TensorUnit>(ctx, name)
	, Inputs(ISSUE_WIDTH, this)
	, Outputs(ISSUE_WIDTH, this)
	, impl_(new Impl(this, arch, core))
{}

TensorUnit::~TensorUnit() {
  delete impl_;
}

void TensorUnit::reset() {
  impl_->reset();
}

void TensorUnit::tick() {
  impl_->tick();
}

const TensorUnit::PerfStats &TensorUnit::perf_stats() const {
	return impl_->perf_stats();
}

void TensorUnit::wmma(uint32_t wid,
                      uint32_t fmt_s,
                      uint32_t fmt_d,
                      uint32_t step_m,
                      uint32_t step_n,
                      const std::vector<reg_data_t>& rs1_data,
                      const std::vector<reg_data_t>& rs2_data,
                      const std::vector<reg_data_t>& rs3_data,
                      std::vector<reg_data_t>& rd_data,
                      ExeTraceData* trace_data) {
  impl_->wmma(wid, fmt_s, fmt_d, step_m, step_n, rs1_data, rs2_data, rs3_data, rd_data, trace_data);
}

#ifdef EXT_AG_TCU_ENABLE
void TensorUnit::ldscale(uint32_t wid,
                         const std::vector<reg_data_t>& rs1_data) {
  impl_->ldscale(wid, rs1_data);
}

void TensorUnit::ldmicro(uint32_t wid,
                         const std::vector<reg_data_t>& rs1_data,
                         const std::vector<reg_data_t>& rs2_data) {
  impl_->ldmicro(wid, rs1_data, rs2_data);
}

void TensorUnit::ldflat(uint32_t wid,
                        uint32_t tile_type,
                        uint32_t num_threads,
                        const std::vector<reg_data_t>& rs1_data,
                        std::vector<reg_data_t>& rd_data) {
  impl_->ldflat(wid, tile_type, num_threads, rs1_data, rd_data);
}

void TensorUnit::ag_wmma(uint32_t wid,
                         uint32_t fmt_s,
                         uint32_t fmt_d,
                         uint32_t step_m,
                         uint32_t step_n,
                         const std::vector<reg_data_t>& rs1_data,
                         const std::vector<reg_data_t>& rs2_data,
                         const std::vector<reg_data_t>& rs3_data,
                         std::vector<reg_data_t>& rd_data,
                         ExeTraceData* trace_data) {
  impl_->ag_wmma(wid, fmt_s, fmt_d, step_m, step_n, rs1_data, rs2_data, rs3_data, rd_data, trace_data);
}
#endif
#ifdef EXT_AG_TCU_ENABLE
void TensorUnit::load_scaled_operand(uint32_t wid,
                                     bool is_a,
                                     const TensorUnit::ScaledBlock& block,
                                     std::vector<reg_data_t>& regs) {
  impl_->load_scaled_operand_impl(wid, is_a, block, regs);
}
#endif
