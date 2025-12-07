// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vvortex_afu_shim.h for the primary calling header

#include "Vvortex_afu_shim__pch.h"
#include "Vvortex_afu_shim__Syms.h"
#include "Vvortex_afu_shim___024unit.h"

void Vvortex_afu_shim___024unit___ctor_var_reset(Vvortex_afu_shim___024unit* vlSelf);

Vvortex_afu_shim___024unit::Vvortex_afu_shim___024unit(Vvortex_afu_shim__Syms* symsp, const char* v__name)
    : VerilatedModule{v__name}
    , vlSymsp{symsp}
 {
    // Reset structure values
    Vvortex_afu_shim___024unit___ctor_var_reset(this);
}

void Vvortex_afu_shim___024unit::__Vconfigure(bool first) {
    (void)first;  // Prevent unused variable warning
}

Vvortex_afu_shim___024unit::~Vvortex_afu_shim___024unit() {
}
