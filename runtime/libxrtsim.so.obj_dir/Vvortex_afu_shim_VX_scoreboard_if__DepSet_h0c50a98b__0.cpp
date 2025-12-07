// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vvortex_afu_shim.h for the primary calling header

#include "Vvortex_afu_shim__pch.h"
#include "Vvortex_afu_shim_VX_scoreboard_if.h"

std::string VL_TO_STRING(const Vvortex_afu_shim_VX_scoreboard_if* obj) {
    VL_DEBUG_IF(VL_DBG_MSGF("+                            Vvortex_afu_shim_VX_scoreboard_if::VL_TO_STRING\n"); );
    // Body
    return (obj ? obj->name() : "null");
}
