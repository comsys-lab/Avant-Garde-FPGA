// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vvortex_afu_shim.h for the primary calling header

#ifndef VERILATED_VVORTEX_AFU_SHIM_VX_TRACE_PKG_H_
#define VERILATED_VVORTEX_AFU_SHIM_VX_TRACE_PKG_H_  // guard

#include "verilated.h"


class Vvortex_afu_shim__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vvortex_afu_shim_VX_trace_pkg final : public VerilatedModule {
  public:

    // INTERNAL VARIABLES
    Vvortex_afu_shim__Syms* const vlSymsp;

    // CONSTRUCTORS
    Vvortex_afu_shim_VX_trace_pkg(Vvortex_afu_shim__Syms* symsp, const char* v__name);
    ~Vvortex_afu_shim_VX_trace_pkg();
    VL_UNCOPYABLE(Vvortex_afu_shim_VX_trace_pkg);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};


#endif  // guard
