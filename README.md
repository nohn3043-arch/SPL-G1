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
SPL-G1 is a <strong>hardware causal-audit trusted compute unit (TCU)</strong> — it is not a general-purpose CPU/GPU/NPU, but a dedicated primitive for security scenarios, providing <em>provable hardware-level causal audit</em>. Based on a 2D PIM (processing-in-memory) array and the RA-BUS unified addressing bus, it combines compute capability (SCALAR / VECTOR / MATRIX tri-mode) with hardware-level causal constraint verification, identity anchoring (256-bit), and an irreversible SBC fuse mechanism. Every operation produces an auditable P→Q causal pair; any violation is permanently locked.
</p>

<p style="font-size:15px;line-height:1.8;color:#2C2C2C">
<strong>Phase A — the TCU core capability loop is fully complete.</strong> Capability milestones A1 control flow, A2 true FP16, A3 <code>splcc</code> compiler, A4 data channel, and A6 SBC fuse have all been delivered and verified through RTL simulation — the integrated testbench (<code>tb_G1_Integrated.sv</code>, v3) passes the full Phase-A suite with <strong>0 errors</strong> (Icarus Verilog).
</p>

</div>

<p align="center">— ✦ —</p>

## ✦ Positioning: What SPL-G1 Is (and Is Not)

<div style="max-width:880px;margin:0 auto;padding:0 16px">

<table>
<tr><th>✅ Is</th><th>❌ Is Not</th></tr>
<tr>
<td>Hardware causal-audit trusted compute unit (TCU)</td>
<td>Desktop CPU running Linux / x86 applications</td>
</tr>
<tr>
<td>Verifiable compute primitive with full-lifecycle P→Q traceability</td>
<td>GPU graphics card with thousands of cores and the CUDA ecosystem</td>
</tr>
<tr>
<td>Tri-mode PIM array (SCALAR / VECTOR / MATRIX) with audit on every operation</td>
<td>Data-center-grade NPU accelerator for LLM inference</td>
</tr>
<tr>
<td>Embedded security root for compliance computing, safety-critical audit, and attestation workloads</td>
<td>A replacement for any mainstream microprocessor</td>
</tr>
</table>

</div>

<p align="center">— ✦ —</p>

## ✦ Quick Start

```bash
# Primary: GitHub
git clone https://github.com/nohn3043-arch/SPL-G1.git
# Mirror: Gitee (this repository)
# git clone https://gitee.com/nohn-ecosystem/SPL-G1-General-purpose-processor.git
cd SPL-G1

# Core EDA toolchain — pure Python >=3.8, standard library only
make demo-causal

# EDA -> RTL pipeline: causal design -> PDK mapping -> Verilog configuration
python eda_cli.py --desc examples/causal_chain_demo.json \
  --pdk pdk/silicon_cim_v1.json --strategy min_delay \
  --output outputs/netlist.json --rtl --rtl-dir outputs/rtlgen/

# RTL simulation (requires Icarus Verilog 12.0+)
make sim          # Compile + run: full Phase-A suite, 0 errors
make wave         # Open waveform in GTKWave

# Compile a C-subset program to SPL-G1 microcode and verify semantics
python splcc.py tests/loop_sub.c --verify
```

<p align="center">— ✦ —</p>

## ✦ Core Contents

<div style="max-width:880px;margin:0 auto;padding:0 16px">

- **Hardware causal-audit pipeline** — every compute step carries an observable P→Q causal trace; audit failure → SBC fuse blown → output permanently zeroed (Materica #4).
- **Tri-mode PIM compute array** — 4×4 processing-in-memory grid (Cell v2: 64-bit local storage + 32-operand ALU), three execution modes SCALAR / VECTOR / MATRIX, 8-bit adjacent interconnect, per-column vec_sum, full-array mat_total reduction.
- **True FP16 (IEEE 754 half-precision)** — sign / 5-bit exponent / 10-bit mantissa, subnormals / NaN / ±Inf, `roundTiesToEven`; real `FP16_ADD / SUB / MUL / CMP / MAC` semantics (A2).
- **Causal constraint (v2)** — `spl_cim_causal_unit` v2 hard-constraint verification: `constraint_pass = (constraint_bits == 64'hFFFF_FFFF_FFFF_FFFF)` + 56-bit `dep_mask` dependency verification with cascading failure. In passthrough (bridge) mode constraint_bits all-ones → always passes (A5).
- **Sequencer v4** — parameterized 256-entry program memory, JMP / JZ / JNZ / CALL / RET / HALT control-flow instructions, 8-level return stack, out-of-bounds protection; RA-BUS READ transaction status (v5 annotation) for the data channel (A4).
- **RA-BUS arbiter v1** — 4-target address-decoding bus (PIM / Audit / Identity / External), READ / WRITE / EXECUTE / CONFIG transaction types.
- **Identity anchor v1** — 256-bit hardware identity verification, 64-cycle bit-by-bit handshake.
- **SBC fuse** — audit failure → `fuse_blown` latch → output forced to zero; only hardware reset can recover (A6).
- **EDA toolchain (pure Python, standard library only)** — `eda_cli.py` drives parse → map → build → export → RTL generation (`eda_parser.py` / `eda_mapper.py` / `eda_exporter.py` / `eda_rtlgen.py` / `EDA_fixed.py`).
- **splcc — C-subset compiler v0.1** — compiles a restricted C dialect (int variables, `for` / `while` / `if-else`, arithmetic, comparison) into SPL-G1 microcode CONFIG words, with `--verify` interpreter mode (A3).
- **RTL (SystemVerilog / Verilog)** — integrated top `G1_Top_Integrated.sv` (v3, Phase A) and `G1_Commercial_Top.sv`; core units `spl_pim_cell.sv` (v2, 32-operand + FP16), `spl_pim_compute_array.sv` (v2.1), `spl_pim_sequencer.sv` (v4 control flow / v5 bus readback), `spl_cim_causal_unit.sv` (v2), `ra_bus_arbiter.sv`, `ext_mem_controller.sv`, `materica_compliance_unit.sv` (v2); extension units `spl_tile.sv`, `spl_multi_tile_array.sv`, `spl_mesh_router.sv`, `spl_pim_reduce_tree.sv`; host interface `pcie_cxl_host_if.sv`, legacy `g1_compute_core.sv` / `G1_Top_Interface.v`; testbenches `tb_G1_Integrated.sv` (v3), `tb_cell_v2.sv`, `tb_pim_compute_array.sv`, `tb_materica_compliance.sv`, `tb_G1_Top.sv`.
- **PDK packages** — `silicon_cim_v1.json` (28nm CIM) and `optical_mzi_photonics_v1.json` (photonic).

</div>

<p align="center">— ✦ —</p>

## ✦ Make Targets

<div style="max-width:880px;margin:0 auto;padding:0 16px">

| `make` target | Action |
|---|---|
| `make demo-causal` | Silicon CIM PDK causal chain demo |
| `make demo-audit` | Cognitive audit demo (low-power optimization) |
| `make demo-optical` | Photonic PDK demo |
| `make demo-full` | Full pipeline (COMPUTE operator + `params` consumption) |
| `make demo-hetero` | Single-die heterogeneous mixed-material demo |
| `make build DESC=<json>` | Compile a custom causal design |
| `make sim` / `make wave` | RTL simulation / open waveform |
| `make rtlgen` / `make rtlgen-apply` | EDA → RTL package generation (apply patch to RTL) |
| `make pdk-report` / `make multi-pdk` | Material coverage matrix / multi-PDK batch comparison |
| `make splcc-bridge` | Run `splcc_bridge.py tests/loop_sub.c --verify --emit outputs` |
| `make clean` | Clean build artifacts and `outputs/*.json` |

> RTL simulation requires **Icarus Verilog** (`iverilog` / `vvp`), optionally **GTKWave** to view `.vcd` waveforms.

</div>

<p align="center">— ✦ —</p>

## ✦ Project Structure

```
SPL-G1/
├── eda_cli.py / eda_parser.py / eda_mapper.py / eda_exporter.py /
│   eda_rtlgen.py / EDA_fixed.py / eda_dataflow.py / eda_pdk_report.py
│                                   # EDA toolchain (pure Python)
├── splcc.py / splcc_bridge.py      # C-subset -> SPL-G1 microcode compiler (v0.1)
├── Makefile                        # demo / build / sim / splcc targets
├── rtl/
│   ├── G1_Top_Integrated.sv        # Integrated top v3 (RA-BUS + PIM + Audit + Anchor + Fuse)
│   ├── G1_Commercial_Top.sv        # Commercial top (extensible configuration variants)
│   ├── ra_bus_arbiter.sv           # RA-BUS 4-target arbiter + address decoding
│   ├── spl_pim_cell.sv             # PIM Cell v2: 64-bit storage + 32-operand ALU + adjacent + FP16
│   ├── spl_pim_compute_array.sv    # PIM array v2.1: 4x4, tri-mode, pim_flag output
│   ├── spl_pim_sequencer.sv        # Sequencer v4: 256-entry program memory + control flow (+ v5 READ status)
│   ├── spl_cim_causal_unit.sv      # Causal audit unit v2: constraint verification + cascading
│   ├── ext_mem_controller.sv       # External memory controller (AXI4, RA-BUS target 3)
│   ├── materica_compliance_unit.sv # Materica 4-gate hardware compliance checker (v2)
│   ├── spl_tile.sv · spl_multi_tile_array.sv · spl_mesh_router.sv · spl_pim_reduce_tree.sv  # Extension units
│   ├── pcie_cxl_host_if.sv         # PCIe Gen5 / CXL 2.0 host interface
│   ├── g1_compute_core.sv · G1_Top_Interface.v   # Legacy core / interface
│   ├── tb_G1_Integrated.sv         # Integrated testbench v3 (full Phase-A suite, 0 errors)
│   ├── tb_cell_v2.sv               # Cell v2 32-operand coverage test
│   ├── tb_pim_compute_array.sv     # PIM array standalone test
│   ├── tb_materica_compliance.sv   # Materica compliance unit test
│   └── tb_G1_Top.sv                # Legacy top test
├── pdk/                            # silicon_cim_v1.json, optical_mzi_photonics_v1.json
├── examples/                       # causal / cognitive audit / full pipeline / heterogeneous demos
├── tests/                          # loop_sub.c (splcc test source)
├── outputs/                        # Generated netlists / VCD waveforms / RTL artifacts
├── docs/                           # ra_bus_protocol.md, BASELINE.md, EDA_ITERATION_DONE.md, history/, SPL-EDA 说明书.pdf, SPL-G1 Alignment Matrix.pdf
├── SPL-Core.json                   # ISA definition (v1.0.0-Commercial: SPL-TCU-G1)
├── State_Anchor.pdl                # 256-bit hardware identity anchor protocol
├── Materica-specification          # 4-item material causal mapping specification
├── IMPROVEMENT_PLAN.md             # Current roadmap (v5.0, TCU positioning, Phase A complete)
└── README.md
```

<p align="center">— ✦ —</p>

## ✦ Ecosystem

SPL-G1 is a member of the NOHN AI ecosystem — a family of projects built around second-perspective causal audit and deterministic execution:

| Project | Repository | Role |
|---|---|---|
| **Second-Perspective (GCAE)** | [nohn3043-arch/second-perspective](https://github.com/nohn3043-arch/second-perspective) | Global cognitive audit engine — five-operator causal audit core (IMDA 95/100) |
| **NOMOS** | [nohn3043-arch/second-perspective](https://github.com/nohn3043-arch/second-perspective) (`Intelligent-Decision-Hub--Nomos` branch) | Auditable deterministic decision hub (IMDA 95/100) |
| **SPL-G1** | [nohn3043-arch/SPL-G1](https://github.com/nohn3043-arch/SPL-G1) | Hardware causal-audit trusted compute unit (TCU) |
| **SPL-Virtual-World-Base** | [nohn3043-arch/Second-Reality](https://github.com/nohn3043-arch/Second-Reality) | Virtual-world and metaverse infrastructure (Constitution / Law / Bridge) |
| **Story-Engine** | [nohn3043-arch/story-engine](https://github.com/nohn3043-arch/story-engine) | Long-form narrative consistency engine |
| **Antares** | [nohn3043-arch/Antares](https://github.com/nohn3043-arch/Antares) | GFSIP v1.0 — federated stable interoperability protocol with causal audit |
| **Anthropomorphic-Agent-Engine** | [nohn3043-arch/Anthropomorphic-Agent-Engine](https://github.com/nohn3043-arch/Anthropomorphic-Agent-Engine) | Deterministic anthropomorphic psychology engine (SPL Pure Core V8.0) |
| **PAGES** | [nohn3043-arch/pages](https://github.com/nohn3043-arch/pages) | Official NOHN AI ecosystem landing page |

<p align="center">— ✦ —</p>

## ✦ License & Authorization

This repository is <strong>not open source</strong> and uses a dual-track model: free for personal non-commercial research; government / enterprise use requires a paid commercial license. See [LICENSE](./LICENSE) for details. Patent applied (PCT).

- **Individual researchers** may use it free for non-commercial research under [LICENSE](./LICENSE), but may not use it for any commercial purpose.
- **Government / enterprise users** must obtain written authorization in advance.
- **Apply for a license**: International / Global — [ai@nohnlins.com](mailto:ai@nohnlins.com) · China — [lin@secondai.top](mailto:lin@secondai.top)

<p align="center">
  <a href="https://github.com/nohn3043-arch">GitHub</a>
  &nbsp;·&nbsp;
  <a href="https://www.nohnlins.com/">nohnlins.com</a>
  &nbsp;·&nbsp;
  <a href="mailto:ai@nohnlins.com">ai@nohnlins.com</a>
</p>
<p align="center"><sub>NOHN AI · SPL-G1 · Trusted Compute Unit</sub></p>
