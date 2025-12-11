# Operand Transformer Synthesis & Schematic Viewing

## Quick Start

### 1. Run Synthesis and Open Schematic
```bash
cd /home/yonghun/vortex/operand_transformer/synthesis
make synth
```

This will:
- Create Vivado project
- Elaborate the design (RTL-level schematic)
- Open Vivado GUI with schematic viewer

### 2. Navigate the Schematic

**Key Modules to Explore:**
- **`operand_transformer`** (Top): 16 lane instances
- **`operand_tf_lane`**: Even/Odd element processing
- **`scaling_unit`**: Universal flattening architecture
  - **Frontend**: MX9/HBFP decoders (case statement)
  - **Backend**: Loop-based scale application
  - **Encoder**: FP8/INT8 output formatting

**What to Look For:**

1. **Hierarchical Scaling Loop**
   - Search for: `exp_flattened` signals
   - Should see 4-iteration loop unrolled
   - Each iteration: mux (scale mode selector) + adder/shifter

2. **Priority Encoder (HBFP)**
   - Search for: `decoded_k` in HBFP path
   - Will show cascaded comparators
   - 7-level priority chain

3. **Lane Parallelism**
   - 16 instances of `operand_tf_lane`
   - Each lane has 2 scaling units (even/odd)

4. **Scale Distribution**
   - L1 scale broadcasted to all lanes
   - L2 scale per-lane routing

### 3. Schematic Navigation Tips

```
View → Schematic Settings
  ☑ Show Port Connections
  ☑ Show Signal Names
  ☐ Show Unconnected Ports (reduces clutter)

Right-click on instance → Expand
  - Drill into lane structure
  - View scaling_unit internals

Search (Ctrl+F):
  - Search for signals: "exp_flattened", "decoded_k", "scales_in"
  - Highlight critical paths
```

### 4. Generate Reports

After synthesis, check:
```bash
cat synth_project/operand_tf_synth.runs/synth_1/operand_transformer_utilization_synth.rpt
cat synth_project/operand_tf_synth.runs/synth_1/operand_transformer_timing_summary_synth.rpt
```

## Advanced: Full Synthesis

To see post-synthesis optimized netlist (slower, more detail):

Edit `synth_design.tcl` and uncomment lines 30-34, then:
```bash
make synth
```

This shows how Vivado optimizes:
- Loop unrolling
- Constant propagation
- Multiplexer optimization

## Cleanup

```bash
make clean
```
