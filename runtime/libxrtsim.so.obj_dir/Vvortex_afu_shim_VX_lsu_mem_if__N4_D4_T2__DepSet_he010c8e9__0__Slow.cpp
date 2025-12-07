// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vvortex_afu_shim.h for the primary calling header

#include "Vvortex_afu_shim__pch.h"
#include "Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2.h"

VL_ATTR_COLD void Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2___ctor_var_reset(Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vvortex_afu_shim__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+                          Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2___ctor_var_reset\n"); );
    auto &vlSelfRef = std::ref(*vlSelf).get();
    // Body
    VL_RAND_RESET_W(283, vlSelf->req_data);
}
