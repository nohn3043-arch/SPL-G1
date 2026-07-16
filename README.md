<p align="center">
  <img src="assets/banner.svg" alt="SPL-G1 banner" style="width:100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/hardware--D4AF37?style=flat-square" alt="hardware">
  <img src="https://img.shields.io/badge/cpu-gpu-npu-D4AF37?style=flat-square" alt="cpu-gpu-npu">
  <img src="https://img.shields.io/badge/causal-audit-D4AF37?style=flat-square" alt="causal-audit">
</p>

<blockquote align="center">
  <em>General-Purpose Processor · 4-in-1 Causal Audit Pipeline</em>
</blockquote>

<div style="max-width:880px;margin:0 auto;padding:0 16px">

## ✦ About

<p style="font-size:15px;line-height:1.8;color:#2C2C2C">SPL-G1 is a 4-in-1 hardware causal audit pipeline that unifies CPU, GPU, NPU, and persistent memory under a single execution plane with causal-level observable audit across the entire compute lifecycle. Built around the RA-BUS interconnect, it converges heterogeneous compute into one verifiable execution surface, providing a hardware foundation for compliance computing and trustworthy AI inference.</p>

<p align="center">
  <img src="assets/overview.svg" alt="SPL-G1 overview" style="width:100%">
</p>

</div>

<p align="center">— ✦ —</p>

## ✦ Quick Start

```bash
git clone git@github.com:NOHN-AI/SPL-G1-GENERAL-PURPOSE-PROCESSOR.git
cd SPL-G1-GENERAL-PURPOSE-PROCESSOR
# Core EDA toolchain is pure Python ≥3.8 — standard library only
make demo-causal          # causal-chain demo (see Makefile for all targets)
# or run the CLI directly:
python eda_cli.py --desc examples/causal_chain_demo.json --pdk pdk/silicon_cim_v1.json --strategy min_delay --output outputs/netlist.json
```

<p align="center">— ✦ —</p>

## ✦ What's Inside

<div style="max-width:880px;margin:0 auto;padding:0 16px">

- **4-in-1 compute fabric** — CPU / GPU / NPU / persistent memory unified on one execution plane via the **RA-BUS** interconnect.
- **Hardware causal-audit pipeline** — every compute step carries an observable causal trail across the full lifecycle.
- **EDA toolchain (pure Python, stdlib-only)** — `eda_cli.py` drives parse → map → build → export:
  - `eda_parser.py` — reads the causal-design JSON
  - `eda_mapper.py` — maps operators to PDK cells
  - `eda_exporter.py` — emits netlist / reports
  - `EDA_fixed.py` — hardened helper routines
- **RTL / silicon + photonics** — SystemVerilog compute core (`g1_compute_core.sv`, `spl_cim_causal_unit.sv`), top interface (`G1_Top_Interface.v`), and a testbench (`tb_G1_Top.sv`).
- **PDK packs** — `silicon_cim_v1.json` (compute-in-memory) and `optical_mzi_photonics_v1.json` (photonic).

</div>

## ✦ Make Targets

<div style="max-width:880px;margin:0 auto;padding:0 16px">

| `make` target | What it runs |
|---|---|
| `make demo-causal` | Causal-chain demo on the silicon CIM PDK |
| `make demo-audit` | Cognitive-audit demo (low-power optimization) |
| `make demo-optical` | Photonic PDK demo |
| `make demo-full` | Full pipeline (COMPUTE operator + `params` consumption) |
| `make build DESC=<json>` | Compile a custom causal design |
| `make sim` / `make wave` | RTL simulation (`iverilog`) + open waveform |

> RTL simulation needs **Icarus Verilog** (`iverilog` / `vvp`) and optionally **GTKWave** for viewing `.vcd` waveforms.

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
├── eda_cli.py / eda_parser.py / eda_mapper.py / eda_exporter.py / EDA_fixed.py
├── Makefile                       # demo / build / sim targets
├── rtl/                          # SystemVerilog: g1_compute_core.sv, spl_cim_causal_unit.sv, G1_Top_Interface.v, tb_G1_Top.sv
├── pdk/                          # silicon_cim_v1.json, optical_mzi_photonics_v1.json
├── examples/                     # causal / cognitive-audit / full-pipeline demos
├── outputs/                      # generated netlists
├── SPL-Core.json · State_Anchor.pdl · Materica-specification
├── docs/                         # SPL-EDA 说明书.pdf, SPL-G1 Alignment Matrix.pdf
└── assets/                       # banner.svg, overview.svg
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
<p align="center"><sub>NOHN AI · SPL-G1</sub></p>
