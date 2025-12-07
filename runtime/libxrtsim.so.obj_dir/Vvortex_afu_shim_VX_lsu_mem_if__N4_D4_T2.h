// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vvortex_afu_shim.h for the primary calling header

#ifndef VERILATED_VVORTEX_AFU_SHIM_VX_LSU_MEM_IF__N4_D4_T2_H_
#define VERILATED_VVORTEX_AFU_SHIM_VX_LSU_MEM_IF__N4_D4_T2_H_  // guard

#include "verilated.h"


class Vvortex_afu_shim__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2 final : public VerilatedModule {
  public:

    // DESIGN SPECIFIC STATE
    VlWide<9>/*282:0*/ req_data;

    // INTERNAL VARIABLES
    Vvortex_afu_shim__Syms* const vlSymsp;

    // CONSTRUCTORS
    Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2(Vvortex_afu_shim__Syms* symsp, const char* v__name);
    ~Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2();
    VL_UNCOPYABLE(Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};

std::string VL_TO_STRING(const Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2* obj);

#endif  // guard
