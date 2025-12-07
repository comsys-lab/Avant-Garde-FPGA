// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vvortex_afu_shim.h for the primary calling header

#include "Vvortex_afu_shim__pch.h"
#include "Vvortex_afu_shim_VX_trace_pkg.h"
#include "Vvortex_afu_shim__Syms.h"

void Vvortex_afu_shim_VX_trace_pkg___ctor_var_reset(Vvortex_afu_shim_VX_trace_pkg* vlSelf);

Vvortex_afu_shim_VX_trace_pkg::Vvortex_afu_shim_VX_trace_pkg(Vvortex_afu_shim__Syms* symsp, const char* v__name)
    : VerilatedModule{v__name}
    , vlSymsp{symsp}
 {
    // Reset structure values
    Vvortex_afu_shim_VX_trace_pkg___ctor_var_reset(this);
}

void Vvortex_afu_shim_VX_trace_pkg::__Vconfigure(bool first) {
    (void)first;  // Prevent unused variable warning
}

Vvortex_afu_shim_VX_trace_pkg::~Vvortex_afu_shim_VX_trace_pkg() {
}
