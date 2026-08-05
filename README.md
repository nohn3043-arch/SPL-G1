<p align="center">
  <img src="https://sourceforge.net/p/spl-g1/git/ci/main/tree/assets/banner.png?format=raw" alt="SPL-G1 banner" style="width:100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/trusted--compute-unit-D4AF37?style=flat-square" alt="trusted-compute-unit">
  <img src="https://img.shields.io/badge/causal-audit-D4AF37?style=flat-square" alt="causal-audit">
  <img src="https://img.shields.io/badge/pim-array-D4AF37?style=flat-square" alt="pim-array">
</p>

<blockquote align="center">
  <em>Hardware Causal-Audit Trusted Compute Unit (TCU) · Second-Perspective Logic Engine</em>
</blockquote>

<div style="max-width:880px;margin:0 auto;padding:0 16px">

## ✦ About

<p style="font-size:15px;line-height:1.8;color:#2C2C2C">
SPL-G1 is a <strong>hardware causal-audit Trusted Compute Unit (TCU)</strong> — not a general-purpose CPU/GPU/NPU, but a dedicated security primitive that provides <em>provable hardware-level causal audit</em> across the entire compute lifecycle. Built on a 2D PIM (Processing-In-Memory) array with the RA-BUS unified address fabric, it combines computational capability (tri-mode SCALAR / VECTOR / MATRIX) with hardware-enforced causal constraint checking, identity anchoring (256-bit), and an irreversible SBC fuse mechanism. Every operation produces an auditable P→Q causal pair, every violation is permanently locked down.
</p>

<p align="center">
  <img src="https://sourceforge.net/p/spl-g1/git/ci/main/tree/assets/overview.svg?format=raw" alt="SPL-G1 overview" style="width:100%">
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
git clone git@github.com:NOHN-AI/SPL-G1-General-purpose-processor.git
cd SPL-G1-General-purpose-processor

# Core EDA toolchain — pure Python ≥3.8, stdlib only
make demo-causal

# EDA → RTL pipeline: causal design → PDK map → Verilog config
python eda_cli.py --desc examples/causal_chain_demo.json \
  --pdk pdk/silicon_cim_v1.json --strategy min_delay \
  --output outputs/netlist.json --rtl --rtl-dir outputs/rtlgen/

# RTL simulation (Icarus Verilog 12.0+ required)
# Add to PATH if needed: $env:PATH = "C:\iverilog\bin;$env:PATH"
make sim          # compile + run: 10 tests, all passed (Phase A v3)
make wave         # open waveforms in GTKWave
```

<p align="center">— ✦ —</p>

## ✦ What's Inside

<div style="max-width:880px;margin:0 auto;padding:0 16px">

- **Hardware causal-audit pipeline** — every compute step carries an observable P→Q causal trail; audit failure → SBC fuse blown → output permanently zeroed (Materica #4).
- **Tri-mode PIM compute array** — 4×4 storage-in-memory grid (Cell v2: 64-bit local store + 32‑op ALU), with SCALAR / VECTOR / MATRIX execution modes, 8‑bit neighbour interconnect, per-col vec_sum, and full-array mat_total reduction.
- **Sequencer v4** — parameterized 256‑entry program memory with JMP / JZ / JNZ / CALL / RET / HALT control‑flow instructions and an 8‑deep return stack.
- **RA-BUS arbiter** — 4‑target address‑decoded bus fabric (PIM / Audit / Identity / External) with READ / WRITE / EXECUTE / CONFIG transaction types.
- **Identity anchor** — 256‑bit hardware identity verification, 64‑cycle nibble‑by‑nibble handshake.
- **SBC fuse** — audit failure → `fuse_blown` latch → output data forced to zero; recovery only via hardware reset.
- **EDA toolchain (pure Python, stdlib‑only)** — `eda_cli.py` drives parse → map → build → export → RTL generation:
  - `eda_parser.py` — reads causal‑design JSON
  - `eda_mapper.py` — maps operators to PDK variants
  - `eda_exporter.py` — emits netlist and reports
  - `eda_rtlgen.py` — emits `spl_config_pkg.sv` + `tb_stimulus.sv` + `syn_tcl.tcl`
  - `EDA_fixed.py` — Material Library + PAL routines
- **RTL (SystemVerilog)** — `G1_Top_Integrated.sv` (full integrated top, v3), `ra_bus_arbiter.sv`, `spl_pim_compute_array.sv` (v2.1), `spl_pim_sequencer.sv` (v4), `spl_pim_cell.sv` (v2), `spl_cim_causal_unit.sv` (v2), `ext_mem_controller.sv`, `materica_compliance_unit.sv`, with integration testbench `tb_G1_Integrated.sv` (v3, 10 tests).
- **PDK packs** — `silicon_cim_v1.json` (28nm CIM) and `optical_mzi_photonics_v1.json` (photonic).

</div>

## ✦ Make Targets

<div style="max-width:880px;margin:0 auto;padding:0 16px">

| `make` target | What it runs |
|---|---|
| `make demo-causal` | Causal‑chain demo on the silicon CIM PDK |
| `make demo-audit` | Cognitive‑audit demo (low‑power optimization) |
| `make demo-optical` | Photonic PDK demo |
| `make demo-full` | Full pipeline (COMPUTE operator + `params` consumption) |
| `make build DESC=<json>` | Compile a custom causal design |
| `make sim` / `make wave` | RTL simulation + open waveform |

> RTL simulation needs **Icarus Verilog** (`iverilog` / `vvp`) and optionally **GTKWave** for `.vcd` waveforms. Install: `winget install icarusVerilog` or download from [bleyer.org/icarus](https://bleyer.org/icarus/).

</div>

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

</div>

## ✦ Project Structure

```
SPL-G1-General-purpose-processor/
├── eda_cli.py / eda_parser.py / eda_mapper.py / eda_exporter.py /
│   eda_rtlgen.py / EDA_fixed.py         # EDA toolchain (pure Python)
├── Makefile                             # demo / build / sim targets
├── rtl/
│   ├── G1_Top_Integrated.sv            # Full integrated top v3 (RA-BUS + PIM + Audit + Anchor + Fuse)
│   ├── ra_bus_arbiter.sv               # RA-BUS 4-target arbiter + address decoder
│   ├── spl_pim_cell.sv                 # PIM Cell v2: 64-bit store + 32-op ALU + neighbour
│   ├── spl_pim_compute_array.sv        # PIM Array v2.1: 4×4, tri-mode, pim_flag output
│   ├── spl_pim_sequencer.sv            # Sequencer v4: 256-entry prog mem + control-flow
│   ├── spl_cim_causal_unit.sv          # Causal Audit Unit v2: constraint check + cascade
│   ├── ext_mem_controller.sv           # External memory controller (AXI4, RA-BUS target 3)
│   ├── materica_compliance_unit.sv     # Materica 4-gate hardware compliance checker
│   ├── tb_G1_Integrated.sv             # Integration testbench v3 (10 tests, 0 errors)
│   └── tb_pim_compute_array.sv         # PIM array standalone testbench
├── pdk/                                # silicon_cim_v1.json, optical_mzi_photonics_v1.json
├── examples/                           # causal / cognitive-audit / full-pipeline demos
├── outputs/                            # generated netlists / VCD waveforms / RTL artifacts
├── docs/                               # ra_bus_protocol.md
├── SPL-Core.json                       # ISA definition (v0.3: 16 instructions + control-flow)
├── State_Anchor.pdl                    # 256-bit hardware identity anchor protocol
├── Materica-specification              # 4-requirement material causality mapping spec
├── IMPROVEMENT_PLAN.md                 # Current improvement roadmap (v4.0, TCU positioning)
└── README.md
```

## ✦ License & Authorization

This repository is **not open-source**. It uses a dual-track model: free for individual non-commercial research, paid commercial authorization required for government / enterprise. See [LICENSE](./LICENSE). Patent-pending (PCT).

<p align="center">
  <a href="https://github.com/NOHN-AI">NOHN-AI</a>
  &nbsp;·&nbsp;
  <a href="https://www.nohnlins.com/">nohnlins.com</a>
  &nbsp;·&nbsp;
  <a href="mailto:ai@nohnlins.com">ai@nohnlins.com</a>
</p>
<p align="center"><sub>NOHN AI · SPL-G1 · Trusted Compute Unit</sub></p>
