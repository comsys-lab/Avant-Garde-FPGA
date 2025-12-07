// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vvortex_afu_shim.h for the primary calling header

#ifndef VERILATED_VVORTEX_AFU_SHIM_VX_RESULT_IF__TZ97_H_
#define VERILATED_VVORTEX_AFU_SHIM_VX_RESULT_IF__TZ97_H_  // guard

#include "verilated.h"


class Vvortex_afu_shim__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vvortex_afu_shim_VX_result_if__Tz97 final : public VerilatedModule {
  public:

    // DESIGN SPECIFIC STATE
    VlWide<6>/*174:0*/ data;

    // INTERNAL VARIABLES
    Vvortex_afu_shim__Syms* const vlSymsp;

    // CONSTRUCTORS
    Vvortex_afu_shim_VX_result_if__Tz97(Vvortex_afu_shim__Syms* symsp, const char* v__name);
    ~Vvortex_afu_shim_VX_result_if__Tz97();
    VL_UNCOPYABLE(Vvortex_afu_shim_VX_result_if__Tz97);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};

std::string VL_TO_STRING(const Vvortex_afu_shim_VX_result_if__Tz97* obj);

#endif  // guard
