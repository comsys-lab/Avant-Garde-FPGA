// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vvortex_afu_shim.h for the primary calling header

#include "Vvortex_afu_shim__pch.h"
#include "Vvortex_afu_shim_VX_mem_bus_if__D40_T7.h"

VL_ATTR_COLD void Vvortex_afu_shim_VX_mem_bus_if__D40_T7___ctor_var_reset(Vvortex_afu_shim_VX_mem_bus_if__D40_T7* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vvortex_afu_shim__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+                          Vvortex_afu_shim_VX_mem_bus_if__D40_T7___ctor_var_reset\n"); );
    auto &vlSelfRef = std::ref(*vlSelf).get();
    // Body
    VL_RAND_RESET_W(613, vlSelf->req_data);
    VL_RAND_RESET_W(519, vlSelf->rsp_data);
}
