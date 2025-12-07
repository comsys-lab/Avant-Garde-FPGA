// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vvortex_afu_shim.h for the primary calling header

#ifndef VERILATED_VVORTEX_AFU_SHIM_VX_MEM_BUS_IF__D40_T5_H_
#define VERILATED_VVORTEX_AFU_SHIM_VX_MEM_BUS_IF__D40_T5_H_  // guard

#include "verilated.h"


class Vvortex_afu_shim__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vvortex_afu_shim_VX_mem_bus_if__D40_T5 final : public VerilatedModule {
  public:

    // DESIGN SPECIFIC STATE
    VlWide<20>/*610:0*/ req_data;
    VlWide<17>/*516:0*/ rsp_data;

    // INTERNAL VARIABLES
    Vvortex_afu_shim__Syms* const vlSymsp;

    // CONSTRUCTORS
    Vvortex_afu_shim_VX_mem_bus_if__D40_T5(Vvortex_afu_shim__Syms* symsp, const char* v__name);
    ~Vvortex_afu_shim_VX_mem_bus_if__D40_T5();
    VL_UNCOPYABLE(Vvortex_afu_shim_VX_mem_bus_if__D40_T5);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};

std::string VL_TO_STRING(const Vvortex_afu_shim_VX_mem_bus_if__D40_T5* obj);

#endif  // guard
