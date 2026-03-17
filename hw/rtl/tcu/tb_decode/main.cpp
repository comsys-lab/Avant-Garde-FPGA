// Verilator C++ harness for tb_decode (Level 8)
// Supports runtime VCD tracing: pass +trace or +trace=<file>
#include "Vtb_decode.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstring>
#include <memory>

int main(int argc, char **argv) {
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);
    const std::unique_ptr<Vtb_decode> dut{new Vtb_decode{contextp.get()}};

    // Parse +trace or +trace=<file> from argv
    const char *vcd_file = nullptr;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "+trace=", 7) == 0) vcd_file = argv[i] + 7;
        else if (strcmp(argv[i], "+trace") == 0) vcd_file = "wave_decode.vcd";
    }

    VerilatedVcdC *vcd = nullptr;
    if (vcd_file) {
        contextp->traceEverOn(true);
        vcd = new VerilatedVcdC;
        dut->trace(vcd, 99);
        vcd->open(vcd_file);
        fprintf(stderr, "[TRACE] Writing waveform to: %s\n", vcd_file);
    }

    // MAX_TIME in ns (--timescale-override 1ns/1ns → 1 time unit = 1ns)
    // 7 TCs × ~500 cycles × 10ns + large margin = 500000 ns (500μs)
    const vluint64_t MAX_TIME = 500000;

    dut->eval();
    if (vcd) vcd->dump(contextp->time());

    while (!contextp->gotFinish() && contextp->time() < MAX_TIME) {
        contextp->timeInc(1);
        dut->eval();
        if (vcd) vcd->dump(contextp->time());
    }

    if (!contextp->gotFinish()) {
        fprintf(stderr, "[ERROR] Simulation timed out after %llu ps\n",
                (unsigned long long)contextp->time());
    }

    dut->final();
    if (vcd) { vcd->close(); delete vcd; }
    return contextp->gotFinish() ? 0 : 1;
}
