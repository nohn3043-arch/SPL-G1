<p align="center">
  <img src="https://img.shields.io/badge/trusted--compute-unit-D4AF37?style=flat-square" alt="trusted-compute-unit">
  <img src="https://img.shields.io/badge/causal-audit-D4AF37?style=flat-square" alt="causal-audit">
  <img src="https://img.shields.io/badge/pim-array-D4AF37?style=flat-square" alt="pim-array">
  <img src="https://img.shields.io/badge/fp16-IEEE754-D4AF37?style=flat-square" alt="fp16">
  <img src="https://img.shields.io/badge/splcc-v0.1-D4AF37?style=flat-square" alt="splcc">
  <img src="https://img.shields.io/badge/phase-a--complete-D4AF37?style=flat-square" alt="phase-a-complete">
</p>

<blockquote align="center">
  <em>Hardware Causal-Audit Trusted Compute Unit (TCU) · Second-Perspective Logic Engine</em>
</blockquote>

<div style="max-width:880px;margin:0 auto;padding:0 16px">

## ✦ About

<p style="font-size:15px;line-height:1.8;color:#2C2C2C">
SPL-G1 is a <strong>hardware causal-audit Trusted Compute Unit (TCU)</strong> — not a general-purpose CPU/GPU/NPU, but a dedicated security primitive that provides <em>provable hardware-level causal audit</em> across the entire compute lifecycle. Built on a 2D PIM (Processing-In-Memory) array with the RA-BUS unified address fabric, it combines computational capability (tri-mode SCALAR / VECTOR / MATRIX) with hardware-enforced causal constraint checking, identity anchoring (256-bit), and an irreversible SBC fuse mechanism. Every operation produces an auditable P→Q causal pair; every violation is permanently locked down.
</p>

<p style="font-size:15px;line-height:1.8;color:#2C2C2C">
<strong>Phase A — TCU core capability loop — is complete.</strong> Capability milestones A1 control-flow, A2 true FP16, A3 <code>splcc</code> compiler, A4 data channel, A6 SBC fuse are delivered and verified in RTL simulation — the integrated testbench (<code>tb_G1_Integrated.sv</code>, v3) runs the full Phase-A suite with <strong>0 errors</strong> (Icarus Verilog). A5 causal constraints are implemented at the v2 level (hard-constraint all-ones check + dependency-mask cascade); the v1 programmable <code>audit_constraint_mask</code> / per-class forbid path is planned (see <a href="./IMPROVEMENT_PLAN.md">IMPROVEMENT_PLAN</a>).
</p>

</div>

<p align="center">— ✦ —</p>

## ✦ Positioning: What SPL-G1 Is (and Isn't)

<div style="max-width:880px;margin:0 auto;padding:0 16px">

<table>
<tr><th>✅ Is</th><th>❌ Is Not</th></tr>
<tr>
<td>A hardware causal-audit Trusted Compute Unit (TCU)</td>
<td>A desktop CPU running Linux or x86 applications</td>
</tr>
<tr>
<td>A verifiable compute primitive with full-lifecycle P→Q provenance</td>
<td>A GPU card with thousands of cores and CUDA stack</td>
</tr>
<tr>
<td>A tri-mode PIM array (SCALAR / VECTOR / MATRIX) with per-op audit</td>
<td>A datacenter-scale NPU accelerator for LLM inference</td>
</tr>
<tr>
<td>Intended as an embedded security root for compliance computing, safety-critical audit, and attestation workloads</td>
<td>A replacement for any mainstream microprocessor</td>
</tr>
</table>

</div>

<p align="center">— ✦ —</p>

## ✦ Quick Start

```bash
# Primary: GitHub
git clone https://github.com/nohn3043-arch/SPL-G1-General-purpose-processor.git
# Mirror: Gitee
# git clone https://gitee.com/nohn-ecosystem/SPL-G1-General-purpose-processor.git
cd SPL-G1-General-purpose-processor

# Core EDA toolchain — pure Python ≥3.8, stdlib only
make demo-causal

# EDA → RTL pipeline: causal design → PDK map → Verilog config
python eda_cli.py --desc examples/causal_chain_demo.json \
  --pdk pdk/silicon_cim_v1.json --strategy min_delay \
  --output outputs/netlist.json --rtl --rtl-dir outputs/rtlgen/

# RTL simulation (Icarus Verilog 12.0+ required)
# Add to PATH if needed: $env:PATH = "C:\iverilog\bin;$env:PATH"
make sim          # compile + run: full Phase-A suite, 0 errors
make wave         # open waveforms in GTKWave

# Compile a C-subset program to SPL-G1 microcode and verify semantics
make splcc-bridge                 # C → microcode bridge (verify mode)
python splcc.py tests/loop_sub.c --verify
```

<p align="center">— ✦ —</p>

## ✦ What's Inside

<div style="max-width:880px;margin:0 auto;padding:0 16px">

- **Hardware causal-audit pipeline** — every compute step carries an observable P→Q causal trail; audit failure → SBC fuse blown → output permanently zeroed (Materica #4).
- **Tri-mode PIM compute array** — 4×4 storage-in-memory grid (Cell v2: 64-bit local store + 32-op ALU), with SCALAR / VECTOR / MATRIX execution modes, 8-bit neighbour interconnect, per-col vec_sum, and full-array mat_total reduction.
- **True FP16 (IEEE 754 half-precision)** — sign / 5-bit exponent / 10-bit mantissa, subnormal / NaN / ±Inf, `roundTiesToEven`. Real `FP16_ADD / SUB / MUL / CMP / MAC` semantics replace integer stubs (A2).
- **Causal constraints (v2)** — `spl_cim_causal_unit` v2 performs hard-constraint checking: `constraint_pass = (constraint_bits == 64'hFFFF_FFFF_FFFF_FFFF)` plus a 56-bit `dep_mask` dependency check with cascade invalidation. Pass-through (bridge) mode has `constraint_bits` all-1s → always passes. (A5)
- **Sequencer v4** — parameterized 256-entry program memory with JMP / JZ / JNZ / CALL / RET / HALT control-flow instructions, 8-deep return stack, OOB protection. The RA-BUS READ transaction (`SEQ_READ`) state is present (annotated v5) for the data channel (A4).
- **RA-BUS arbiter v1** — 4-target address-decoded bus fabric (PIM / Audit / Identity / External) with READ / WRITE / EXECUTE / CONFIG transaction types.
- **Identity anchor v1** — 256-bit hardware identity verification, 64-cycle nibble-by-nibble handshake.
- **SBC fuse** — audit failure → `fuse_blown` latch → output data forced to zero; recovery only via hardware reset (A6).
- **EDA toolchain (pure Python, stdlib-only)** — `eda_cli.py` drives parse → map → build → export → RTL generation:
  - `eda_parser.py` — reads causal-design JSON
  - `eda_mapper.py` — maps operators to PDK variants
  - `eda_exporter.py` — emits netlist and reports
  - `eda_rtlgen.py` — emits `spl_config_pkg.sv` + `tb_stimulus.sv` + `syn_tcl.tcl`
  - `EDA_fixed.py` — Material Library + PAL routines
- **splcc — C-subset compiler v0.1** — `splcc.py` turns a restricted C dialect (int vars, `for` / `while` / `if-else`, arithmetic, comparison) into SPL-G1 microcode CONFIG words, with an `--verify` interpreter mode (`splcc_bridge.py` wraps it for the test flow). C→microcode proven feasible; arrays/pointers/functions are v0.2+ (A3).
- **RTL (SystemVerilog / Verilog)** — integrated top `G1_Top_Integrated.sv` (v3, Phase A) plus `G1_Commercial_Top.sv`; core units `spl_pim_cell.sv` (v2, 32-op + FP16), `spl_pim_compute_array.sv` (v2.1), `spl_pim_sequencer.sv` (v4 control-flow / v5 bus-readback), `spl_cim_causal_unit.sv` (v2), `ra_bus_arbiter.sv`, `ext_mem_controller.sv`, `materica_compliance_unit.sv` (v2); scaling units `spl_tile.sv`, `spl_multi_tile_array.sv`, `spl_mesh_router.sv`, `spl_pim_reduce_tree.sv`; host interface `pcie_cxl_host_if.sv`, legacy `g1_compute_core.sv` / `G1_Top_Interface.v`; testbenches `tb_G1_Integrated.sv` (v3), `tb_cell_v2.sv`, `tb_pim_compute_array.sv`, `tb_materica_compliance.sv`, `tb_G1_Top.sv`.
- **PDK packs** — `silicon_cim_v1.json` (28nm CIM) and `optical_mzi_photonics_v1.json` (photonic).

</div>

<p align="center">— ✦ —</p>

## ✦ Make Targets

<div style="max-width:880px;margin:0 auto;padding:0 16px">

| `make` target | What it runs |
|---|---|
| `make demo-causal` | Causal-chain demo on the silicon CIM PDK |
| `make demo-audit` | Cognitive-audit demo (low-power optimization) |
| `make demo-optical` | Photonic PDK demo |
| `make demo-full` | Full pipeline (COMPUTE operator + `params` consumption) |
| `make demo-hetero` | Heterogeneous single-die mixed-material demo |
| `make build DESC=<json>` | Compile a custom causal design |
| `make sim` / `make wave` | RTL simulation + open waveform |
| `make rtlgen` / `make rtlgen-apply` | EDA → RTL package generation (apply patches to RTL) |
| `make pdk-report` / `make multi-pdk` | Material coverage matrix / multi-PDK batch compare |
| `make splcc-bridge` | Run `splcc_bridge.py tests/loop_sub.c --verify --emit outputs` |
| `make clean` | Remove build artifacts and `outputs/*.json` |

> RTL simulation needs **Icarus Verilog** (`iverilog` / `vvp`) and optionally **GTKWave** for `.vcd` waveforms. Install: `winget install icarusVerilog` or download from [bleyer.org/icarus](https://bleyer.org/icarus/).

</div>

<p align="center">— ✦ —</p>

## ✦ Usage

<div style="max-width:880px;margin:0 auto;padding:0 16px">

```bash
# Run the gold-path causal demo end-to-end
python eda_cli.py \
  --desc examples/causal_chain_demo.json \
  --pdk pdk/silicon_cim_v1.json \
  --strategy min_delay \
  --output outputs/netlist.json
```

Strategy options: `min_delay` · `min_power`. Example designs live in `examples/` (`causal_chain_demo.json`, `cognitive_audit_demo.json`, `full_pipeline_demo.json`).

```bash
# Compile a C-subset program to microcode and verify its semantics
python splcc.py tests/loop_sub.c --verify
#  → prints interpretation of each variable after execution

python splcc.py tests/loop_sub.c --json
#  → emits CONFIG addr/wdata pairs as JSON
```

</div>

<p align="center">— ✦ —</p>

## ✦ Application Paths: Security Audit Node

<div style="max-width:880px;margin:0 auto;padding:0 16px">

- **Industrial safety (audit ledger)** — each process step → P→Q causal record → audit against safety spec → violation/skip → `fuse_blown` → emergency stop + tamper-proof violation log.
- **Compliance computing** — cloud trust question "did the server tamper with the AI inference result?" → TCU side-band audit: every inference step's P→Q label is publicly verifiable.
- **Supply-chain traceability** — "where did this batch come from?" → `State_Anchor` + full-chain P→Q tracking = forgery cannot be covered.

</div>

<p align="center">— ✦ —</p>

## ✦ Scale Ladder & Milestones

<div style="max-width:880px;margin:0 auto;padding:0 16px">

**Scale ladder**

| Level | Scale | Working set | Runs what | Milestone |
|-------|-------|-------------|-----------|-----------|
| L0 prototype | 4×4 = 16 cells | 128 B | demo-grade integer/FP16 ops | ✅ current |
| L1 embedded core | 16×16 = 256 cells | 4 KB | real MCU-class program (needs A3 compiler) | Phase B |
| L2 AI accelerator | 64×64 = 4096 cells | 64 KB | tiny MLP, sensor-end classification | Phase C |
| L3 storage-class | 262,144 cells | 2 MB | industrial audit rulebase + batch trace | needs tape-out |

**Milestones**

| Milestone | Definition | Verification |
|-----------|------------|--------------|
| M1: TCU trust closure | A2+A3+A4+A5 complete | sim runs audit loop, fuse closes |
| M2: first compiler | splcc emits runnable microcode | `for` loop sim passes |
| M3: Tile expansion | 16×16 array | all modes tested |
| M4: Synthesis result | Yosys area/freq/power | tape-out feasibility |

> Known gaps (post Phase A): C5 scale too small (128 B work set); C6 no timing/area/power synthesis yet (Yosys/DC not run).

</div>

<p align="center">— ✦ —</p>

## ✦ Project Structure

```
SPL-G1-General-purpose-processor/
├── eda_cli.py / eda_parser.py / eda_mapper.py / eda_exporter.py /
│   eda_rtlgen.py / EDA_fixed.py / eda_dataflow.py / eda_pdk_report.py
│                                   # EDA toolchain (pure Python)
├── splcc.py / splcc_bridge.py      # C-subset → SPL-G1 microcode compiler (v0.1)
├── Makefile                        # demo / build / sim / splcc targets
├── rtl/
│   ├── G1_Top_Integrated.sv        # Full integrated top v3 (RA-BUS + PIM + Audit + Anchor + Fuse)
│   ├── G1_Commercial_Top.sv        # Commercial top (scalable-config variant)
│   ├── ra_bus_arbiter.sv           # RA-BUS 4-target arbiter + address decoder
│   ├── spl_pim_cell.sv             # PIM Cell v2: 64-bit store + 32-op ALU + neighbour + FP16
│   ├── spl_pim_compute_array.sv    # PIM Array v2.1: 4×4, tri-mode, pim_flag output
│   ├── spl_pim_sequencer.sv        # Sequencer v4: 256-entry prog mem + control-flow (+ v5 READ state)
│   ├── spl_cim_causal_unit.sv      # Causal Audit Unit v2: constraint check + cascade
│   ├── ext_mem_controller.sv       # External memory controller (AXI4, RA-BUS target 3)
│   ├── materica_compliance_unit.sv # Materica 4-gate hardware compliance checker (v2)
│   ├── spl_tile.sv · spl_multi_tile_array.sv · spl_mesh_router.sv · spl_pim_reduce_tree.sv  # scaling units
│   ├── pcie_cxl_host_if.sv         # PCIe Gen5 / CXL 2.0 host interface
│   ├── g1_compute_core.sv · G1_Top_Interface.v   # legacy core / interface
│   ├── tb_G1_Integrated.sv         # Integration testbench v3 (full Phase-A suite, 0 errors)
│   ├── tb_cell_v2.sv               # Cell v2 32-op coverage testbench
│   ├── tb_pim_compute_array.sv     # PIM array standalone testbench
│   ├── tb_materica_compliance.sv   # Materica compliance unit testbench
│   └── tb_G1_Top.sv                # Legacy top testbench
├── pdk/                            # silicon_cim_v1.json, optical_mzi_photonics_v1.json
├── examples/                       # causal / cognitive-audit / full-pipeline / heterogeneous demos
├── tests/                          # loop_sub.c (splcc test source)
├── outputs/                        # generated netlists / VCD waveforms / RTL artifacts
├── docs/                           # ra_bus_protocol.md, BASELINE.md, EDA_ITERATION_DONE.md, history/, SPL-EDA 说明书.pdf, SPL-G1 Alignment Matrix.pdf
├── SPL-Core.json                   # ISA definition (v1.0.0-Commercial: SPL-TCU-G1)
├── State_Anchor.pdl                # 256-bit hardware identity anchor protocol
├── Materica-specification          # 4-requirement material causality mapping spec
├── IMPROVEMENT_PLAN.md             # Current roadmap (v5.0, TCU positioning, Phase A done)
└── README.md
```

<p align="center">— ✦ —</p>

## ✦ Ecosystem

SPL-G1 is one member of the NOHN AI ecosystem — a family of projects built around second-perspective causal audit and deterministic execution:

| Project | Repository | What it is |
|---|---|---|
| **Second-Perspective (GCAE)** | [nohn3043-arch/second-perspective](https://github.com/nohn3043-arch/second-perspective) | Global cognitive audit engine — the five-operator causal audit core (IMDA 95/100) |
| **NOMOS** | [nohn3043-arch/second-perspective](https://github.com/nohn3043-arch/second-perspective) (`Intelligent-Decision-Hub--Nomos` branch) | Auditable deterministic decision hub (IMDA 95/100) |
| **SPL-G1** | [nohn3043-arch/SPL-G1-General-purpose-processor](https://github.com/nohn3043-arch/SPL-G1-General-purpose-processor) | Hardware causal-audit Trusted Compute Unit (TCU) |
| **SPL-Virtual-World-Base** | [nohn3043-arch/Second-Reality](https://github.com/nohn3043-arch/Second-Reality) | Virtual-world & metaverse infrastructure (Constitution / Law / Bridge) |
| **Story-Engine** | [nohn3043-arch/story-engine](https://github.com/nohn3043-arch/story-engine) | Long-form narrative consistency engine |
| **Antares** | [nohn3043-arch/Antares](https://github.com/nohn3043-arch/Antares) | GFSIP v1.0 — federated stable interoperability protocol with causal audit |
| **Anthropomorphic-Agent-Engine** | [nohn3043-arch/Anthropomorphic-Agent-Engine](https://github.com/nohn3043-arch/Anthropomorphic-Agent-Engine) | Deterministic anthropomorphic psychology engine (SPL Pure Core V8.0) |
| **PAGES** | [nohn3043-arch/pages](https://github.com/nohn3043-arch/pages) | Official NOHN AI ecosystem landing page |

<p align="center">— ✦ —</p>

## ✦ License & Authorization

This repository is **not open-source**. It uses a dual-track model: free for individual non-commercial research; paid commercial authorization required for government / enterprise. See [LICENSE](./LICENSE). Patent-pending (PCT).

- **Individual researchers** may use the Work free of charge for non-commercial research under [LICENSE](./LICENSE), but not for any commercial purpose.
- **Government / enterprise users** require prior written authorization.
- **Apply for authorization**: International / Global — [ai@nohnlins.com](mailto:ai@nohnlins.com) · China — [lin@secondai.top](mailto:lin@secondai.top)

<p align="center">
  <a href="https://github.com/nohn3043-arch">GitHub</a>
  &nbsp;·&nbsp;
  <a href="https://www.nohnlins.com/">nohnlins.com</a>
  &nbsp;·&nbsp;
  <a href="mailto:ai@nohnlins.com">ai@nohnlins.com</a>
</p>
<p align="center"><sub>NOHN AI · SPL-G1 · Trusted Compute Unit</sub></p>
