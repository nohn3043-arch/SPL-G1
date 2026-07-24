<p align="center">
  <img src="https://sourceforge.net/p/spl-g1/git/ci/main/tree/assets/banner.png?format=raw" alt="SPL-G1 banner" style="width:100%">
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
  <img src="https://sourceforge.net/p/spl-g1/git/ci/main/tree/assets/overview.svg?format=raw" alt="SPL-G1 overview" style="width:100%">
</p>

</div>

<p align="center">— ✦ —</p>

## ✦ Quick Start

```bash
git clone git@github.com:NOHN-AI/SPL-G1-GENERAL-PURPOSE-PROCESSOR.git
cd SPL-G1-GENERAL-PURPOSE-PROCESSOR

# Core EDA toolchain — pure Python ≥3.8, stdlib only
make demo-causal

# EDA → RTL pipeline: causal design → PDK map → Verilog config + Yosys script
python eda_cli.py --desc examples/causal_chain_demo.json \
  --pdk pdk/silicon_cim_v1.json --strategy min_delay \
  --output outputs/netlist.json --rtl --rtl-dir outputs/rtlgen/

# RTL simulation (iverilog 12.0+ required)
make sim          # run tb_G1_Top (original) + tb_G1_Integrated (full pipeline)
make wave         # open waveforms in GTKWave
```

<p align="center">— ✦ —</p>

## ✦ What's Inside

<div style="max-width:880px;margin:0 auto;padding:0 16px">

- **4-in-1 compute fabric** — CPU / GPU / NPU / persistent memory unified on one execution plane via the **RA-BUS** interconnect.
- **Hardware causal-audit pipeline** — every compute step carries an observable causal trail across the full lifecycle.
- **PIM compute array** — 4×4 storage-in-memory grid with SCALAR / VECTOR / MATRIX execution modes and per-column vec_sum / full-array mat_total aggregation.
- **RA-BUS arbiter** — 4-target address-decoded bus fabric (PIM / Audit / Identity / Reserved) with READ / WRITE / EXECUTE / CONFIG transaction types.
- **EDA toolchain (pure Python, stdlib-only)** — `eda_cli.py` drives parse → map → build → export → RTL generate:
  - `eda_parser.py` — reads the causal-design JSON
  - `eda_mapper.py` — maps operators to PDK cells
  - `eda_exporter.py` — emits netlist / reports
  - `eda_rtlgen.py` — emits `spl_config_pkg.sv` + `tb_stimulus.sv` + `syn_tcl.tcl` from mapping results
  - `EDA_fixed.py` — hardened helper routines
- **RTL (SystemVerilog)** — `G1_Top_Integrated.sv` (full integrated top), `ra_bus_arbiter.sv`, `spl_pim_compute_array.sv`, `spl_pim_sequencer.sv`, `spl_pim_cell.sv`, `spl_cim_causal_unit.sv`, with integration testbench `tb_G1_Integrated.sv`.
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

> RTL simulation needs **Icarus Verilog** (`iverilog` / `vvp`) and optionally **GTKWave** for viewing `.vcd` waveforms. Install: `winget install icarusVerilog` or download from [bleyer.org/icarus](https://bleyer.org/icarus/).

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
│   eda_rtlgen.py / EDA_fixed.py    # EDA toolchain (pure Python)
├── Makefile                        # demo / build / sim targets
├── rtl/
│   ├── G1_Top_Integrated.sv       # Full integrated top (RA-BUS + PIM + Audit + Identity)
│   ├── G1_Top_Interface.v        # Original top (legacy)
│   ├── ra_bus_arbiter.sv          # RA-BUS 4-target arbiter + address decoder
│   ├── g1_compute_core.sv        # Original compute core
│   ├── spl_cim_causal_unit.sv    # Causal audit unit
│   ├── spl_pim_cell.sv           # Single PIM cell: 64-bit store + 8-op ALU
│   ├── spl_pim_compute_array.sv  # 4×4 PIM array: SCALAR / VECTOR / MATRIX modes
│   ├── spl_pim_sequencer.sv      # 16-entry micro-op instruction sequencer
│   ├── tb_G1_Top.sv             # Original top-level testbench (4 tests)
│   ├── tb_G1_Integrated.sv      # Integration testbench via RA-BUS (5 tests)
│   └── tb_pim_compute_array.sv   # PIM array standalone testbench (3 tests)
├── pdk/                           # silicon_cim_v1.json, optical_mzi_photonics_v1.json
├── examples/                      # causal / cognitive-audit / full-pipeline demos
├── docs/ra_bus_protocol.md       # RA-BUS protocol specification
├── outputs/                       # generated netlists / VCD waveforms / RTL artifacts
├── SPL-Core.json · State_Anchor.pdl · Materica-specification
└── spl_g1_phase*.md              # Phase work records
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
