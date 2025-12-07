// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vvortex_afu_shim.h for the primary calling header

#include "Vvortex_afu_shim__pch.h"
#include "Vvortex_afu_shim_VX_decode_if.h"

VL_ATTR_COLD void Vvortex_afu_shim_VX_decode_if___ctor_var_reset(Vvortex_afu_shim_VX_decode_if* vlSelf) {
    (void)vlSelf;  // Prevent unused variable warning
    Vvortex_afu_shim__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    VL_DEBUG_IF(VL_DBG_MSGF("+                          Vvortex_afu_shim_VX_decode_if___ctor_var_reset\n"); );
    auto &vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelf->ready = VL_RAND_RESET_I(1);
}
