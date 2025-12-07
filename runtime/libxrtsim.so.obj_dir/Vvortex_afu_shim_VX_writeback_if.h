// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vvortex_afu_shim.h for the primary calling header

#ifndef VERILATED_VVORTEX_AFU_SHIM_VX_WRITEBACK_IF_H_
#define VERILATED_VVORTEX_AFU_SHIM_VX_WRITEBACK_IF_H_  // guard

#include "verilated.h"


class Vvortex_afu_shim__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vvortex_afu_shim_VX_writeback_if final : public VerilatedModule {
  public:

    // DESIGN SPECIFIC STATE
    CData/*0:0*/ valid;
    VlWide<6>/*173:0*/ data;

    // INTERNAL VARIABLES
    Vvortex_afu_shim__Syms* const vlSymsp;

    // CONSTRUCTORS
    Vvortex_afu_shim_VX_writeback_if(Vvortex_afu_shim__Syms* symsp, const char* v__name);
    ~Vvortex_afu_shim_VX_writeback_if();
    VL_UNCOPYABLE(Vvortex_afu_shim_VX_writeback_if);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};

std::string VL_TO_STRING(const Vvortex_afu_shim_VX_writeback_if* obj);

#endif  // guard
