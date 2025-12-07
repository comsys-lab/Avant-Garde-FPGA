// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vvortex_afu_shim.h for the primary calling header

#include "Vvortex_afu_shim__pch.h"
#include "Vvortex_afu_shim_VX_trace_pkg.h"
#include "Vvortex_afu_shim__Syms.h"

extern "C" void dpi_trace(int level, const char* format);

VL_INLINE_OPT void Vvortex_afu_shim_VX_trace_pkg____Vdpiimwrap_dpi_trace_TOP__VX_trace_pkg(IData/*31:0*/ level, std::string format) {
    VL_DEBUG_IF(VL_DBG_MSGF("+        Vvortex_afu_shim_VX_trace_pkg____Vdpiimwrap_dpi_trace_TOP__VX_trace_pkg\n"); );
    // Body
    int level__Vcvt;
    for (size_t level__Vidx = 0; level__Vidx < 1; ++level__Vidx) level__Vcvt = level;
    const char* format__Vcvt;
    for (size_t format__Vidx = 0; format__Vidx < 1; ++format__Vidx) format__Vcvt = format.c_str();
    dpi_trace(level__Vcvt, format__Vcvt);
}
