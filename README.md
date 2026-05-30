# GRAFS — Generic Resource-Aware Fuzzy Service

VHDL implementation of a SOA-based adaptive fuzzy inference framework for FPGA.  
Part of the undergraduate thesis *"A SOA-Based FPGA Framework with Adaptive Fuzzy for Generic Resource Management"* — Universidade SENAI Cimatec, 2026.

**Target device:** Intel Cyclone V `5CGXFC7C7F23C8`  
**Toolchain:** Quartus Prime 22.1 Lite + ModelSim (VHDL-2008)

---

## Overview

GRAFS classifies two sensor inputs into one of three states — **OK**, **ALERT**, or **CRITICAL** — using a Mamdani fuzzy inference pipeline. All membership function parameters are stored in a runtime-configurable Service Registry and updated online between inference cycles by an adaptive engine, without re-synthesis.

The architecture follows a Service-Oriented Architecture (SOA) pattern at the hardware level:

```
system_top
├── ms_client        (Service Requester)
└── ms_broker        (Service Broker)
    ├── config_registers  (Service Registry)
    ├── svc_fuzzy         (Fuzzy Service)
    │   ├── ms_fuzzify ×2     — fuzzification (parallel)
    │   │   └── triangular_mf ×3 each
    │   ├── ms_rule_eval      — 9-rule evaluation (combinational)
    │   ├── ms_aggregate      — MAX aggregation per class (combinational)
    │   └── ms_defuzzify      — weighted average + classification
    └── svc_adapt         (Adapt Service)
        └── ms_adapt          — Welford + sqrt + EMA + registry writes
```

---

## Arithmetic

All values use **Q8.8 fixed-point** (signed 16-bit, resolution ≈ 0.004).  
Intermediate products are computed in Q16.16 (signed 32-bit) and shifted right 8 bits to return to Q8.8.  
No floating-point units are used — the Cyclone V has none.

---

## Service Registry (`config_registers.vhd`)

33 × 16-bit registers, word-addressed:

| Address | Contents |
|---------|----------|
| `0x00–0x08` | MF parameters for Input 1 (a, b, c for LOW / MED / HIGH) |
| `0x09–0x11` | MF parameters for Input 2 |
| `0x12–0x1A` | Rule output classes (9 rules, 2-bit each: `00`=OK, `01`=ALERT, `10`=CRITICAL) |
| `0x1B–0x1D` | Crisp output values for OK, ALERT, CRITICAL (Q8.8) |
| `0x1E` | EMA learning rate `alpha` (Q8.8, e.g. `0x000D` ≈ 0.05) |
| `0x1F` | Adaptation frequency `adapt_every_n` |
| `0x20` | Spread factor `k` (Q8.8, `0x0100` = 1.0) |

Two write ports: external cfg bus (higher priority) and internal `svc_adapt` (addresses `0x00–0x11` only).

---

## Fuzzy Inference Pipeline (`svc_fuzzy.vhd`)

**FSM:** `IDLE → FUZZ_START → FUZZ_WAIT → DEFUZZ_START → DEFUZZ_WAIT → OUTPUT`

1. **Fuzzification** — two `ms_fuzzify` instances run in parallel (~24 cycles each), each instantiating three `triangular_mf` units concurrently (LOW, MED, HIGH).
2. **Rule evaluation** — `ms_rule_eval` computes MIN for each of the 9 rules (combinational).
3. **Aggregation** — `ms_aggregate` computes MAX per output class (combinational).
4. **Defuzzification** — `ms_defuzzify` performs center-of-area weighted average (~35 cycles) and assigns the final class.

---

## Adaptation Engine (`ms_adapt.vhd`)

**FSM:** 22 states. Runs after every inference cycle, outside the critical path.

| Stage | What happens |
|-------|-------------|
| `S_WELFORD_1..6` | Incremental mean/variance update (Welford algorithm) for both inputs. Uses a shared 32-bit restoring divider. |
| `S_CHECK_ADAPT` | Skip to `S_DONE` unless `n mod adapt_every_n == 0`. |
| `S_VARIANCE_1..2` | Compute variance = M2 / (n−1) via shared divider. |
| `S_SQRT_1..2` | Digit-by-digit square root (12 iterations, 2 bits/cycle) → standard deviation. |
| `S_CALC_TARGETS_1..2` | Compute control points: p1 = mean − k·std, p2 = mean, p3 = mean + k·std. Clamped to [in_min, in_max] with minimum separation. |
| `S_EMA_1..2` | Smooth control points: `p_new = p_current + alpha × (p_target − p_current)`. Current values read directly from Service Registry. |
| `S_DERIVE_1..2` | Derive full 9-parameter MF geometry from 3 control points per input. |
| `S_WRITE_REGS` | Write 18 parameters to `config_registers` (addresses `0x00–0x11`), one per clock cycle. |

**Latency:**
- Cycle without full adaptation: ~8 cycles
- Cycle with full adaptation: ~80–120 cycles

**Safety:** `ms_adapt` can only write to `0x00–0x11`. Rule definitions (`0x12–0x1A`), crisp output values (`0x1B–0x1D`), and adaptation parameters (`0x1E–0x20`) are write-protected by hardware.

---

## Broker FSM (`ms_broker.vhd`)

```
IDLE → FUZZY_START → FUZZY_WAIT → OUTPUT → ADAPT_START → ADAPT_WAIT → IDLE
```

The result is delivered to the Service Requester at `OUTPUT`, before adaptation starts — classification latency is not affected by the adaptation cost.

---

## Synthesis Results

Compiled with Quartus Prime 22.1 — Cyclone V `5CGXFC7C7F23C8` (15/03/2026):

| Resource | Used | Total | % |
|----------|------|-------|---|
| ALMs | 3,362 | 56,480 | 6% |
| Registers | 2,267 | — | — |
| DSP Blocks | 13 | 156 | 8% |
| Block RAM | 0 | — | 0% |
| I/O Pins | 143 | 268 | 53% |

---

## Simulation

Seven testbenches cover 6 static inference scenarios and 1 online adaptation validation.

### Running a testbench (ModelSim transcript)

```tcl
do sim_idle.do
```

Available scripts:

| Script | Scenario | Expected result |
|--------|----------|-----------------|
| `sim_idle.do` | Idle server (CPU=5%, MEM=10%) | OK (`0x0055`) |
| `sim_alerta.do` | CPU overload (CPU=84%, MEM=16%) | ALERT (`0x00AB`) |
| `sim_predial_ok.do` | Building normal (T=12%, H=45%) | OK (`0x0055`) |
| `sim_predial_critico.do` | Building critical (T=86%, H=59%) | CRITICAL (`0x00F1`) |
| `sim_clima_ok.do` | Climate risk (R=51%, W=78%) | CRITICAL (`0x00F1`) |
| `sim_clima_alerta.do` | Climate alert (R=55%, W=61%) | ALERT (`0x00AB`) |
| `sim_adaptacao.do` | Online adaptation (10 samples) | MF params updated, class → OK |

### Adaptation testbench result

With inputs fixed at 10 and 20, `adapt_every_n=5`, after one adaptation cycle:

| Parameter | Register | Before | After | Δ |
|-----------|----------|--------|-------|---|
| `in1_c_low` | `0x02` | 150 | 123 | −27 |
| `in1_b_med` | `0x04` | 150 | 139 | −11 |
| `in1_a_high` | `0x06` | 171 | 155 | −16 |
| Post-adaptation class | — | — | OK (`0x00`) | ✓ |

---

## Default Configuration

The shared package `tb_fuzzy_pkg.vhd` loads the default 33 registers:

- **MF shape (both inputs):** LOW shoulder [0, 0, 85] · MED triangle [64, 128, 192] · HIGH shoulder [171, 256, 256]
- **Rule matrix:** (LOW,LOW)=OK · (MED,MED)=ALERT · (HIGH,\*)=ALERT/CRITICAL · (\*,HIGH)=ALERT/CRITICAL
- **Crisp outputs:** OK=85 · ALERT=171 · CRITICAL=241
- **Adaptation:** alpha=13 (~0.05) · N=10 · k=256 (1.0)

---

## File Reference

| File | Role |
|------|------|
| `system_top.vhd` | Top-level entity (Quartus entry point) |
| `ms_client.vhd` | Service Requester — sensor interface and handshake |
| `ms_broker.vhd` | Service Broker — orchestrates fuzzy and adapt services |
| `config_registers.vhd` | Service Registry — 33 × 16-bit configurable parameters |
| `svc_fuzzy.vhd` | Fuzzy Service — Mamdani inference pipeline |
| `ms_fuzzify.vhd` | Microservice — parallel fuzzification (3 MFs per input) |
| `triangular_mf.vhd` | Triangular membership function (sequential divider) |
| `ms_rule_eval.vhd` | Microservice — 9-rule MIN evaluation (combinational) |
| `ms_aggregate.vhd` | Microservice — MAX aggregation per class (combinational) |
| `ms_defuzzify.vhd` | Microservice — CoA defuzzification + classification |
| `svc_adapt.vhd` | Adapt Service — thin wrapper for ms_adapt |
| `ms_adapt.vhd` | Adaptation engine — Welford + sqrt + EMA (22-state FSM) |
| `tb_fuzzy_pkg.vhd` | Shared testbench package (clock, cfg procedures) |
| `testbench_*.vhd` | Scenario testbenches (7 total) |
| `sim_*.do` | ModelSim automation scripts (7 total) |
| `adaptative_fuzzy.qpf/.qsf` | Quartus project files |
