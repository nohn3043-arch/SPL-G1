# Only trustworthy computation has a future.

# SPL‑G1: Second‑Perspective Logic Universal Core
**A Paradigm Shift in State‑Centric, Ultra‑Low‑Power Unified Heterogeneous Computing**
"State Anchor `0x8525d007_59a4ca22` is the composite identity of G1 Architecture. Any unauthorized hardware implementation or software emulation of this logic state will be considered a violation of the SPL (Second Perspective Language) Framework License."
---

### ⚠️ Important Notice
**Legal Status:** All technologies related to this project have been filed for PCT International Patent Application.
**Patent Application No.:** `[PCT/CN2026/094913]`

*All hardware implementation codes, configuration files, and protocol documents are patent-pending technologies. They are provided for **academic reference only**. Any form of commercial replication, hardware physical implementation, or patent circumvention design is strictly prohibited.*

---

## Repository Layout

```
SPL-G1-General-purpose-processor/
├── EDA_fixed.py            # Kernel: causal operator types / CausalIR / parameter consumption / PDK loading (v0.4.0)
├── eda_parser.py           # Causal description JSON → CausalIR parser
├── eda_mapper.py           # Technology mapper (with params affinity tie-breaking)
├── eda_exporter.py         # Netlist JSON + report output (with parameter warnings)
├── eda_cli.py              # CLI entry point
├── pdk/                    # PDK library
│   ├── optical_mzi_photonics_v1.json   # Optical MZI process (6 opcodes incl. COMPUTE)
│   └── silicon_cim_v1.json             # Silicon CIM 28nm process (6 opcodes incl. COMPUTE)
├── examples/               # Causal description examples
│   ├── causal_chain_demo.json          # Full 5-opcode chain demonstration
│   ├── cognitive_audit_demo.json       # Cognitive audit red-line hard-block use case
│   └── full_pipeline_demo.json         # Full pipeline (with COMPUTE + params consumption)
├── rtl/                    # Hardware layer (SystemVerilog v0.2.0)
│   ├── g1_compute_core.sv              # Compute processing core (5 causal compute modes)
│   ├── G1_Top_Interface.v              # G1 top-level interface (compute→audit pipeline + 64-cycle identity anchor)
│   ├── spl_cim_causal_unit.sv          # Causal check unit (8-entry forbidden matrix)
│   └── tb_G1_Top.sv                    # Top-level testbench (4 pass/fail scenarios)
├── docs/                   # Specification documents
│   ├── SPL-EDA 说明书.pdf              # SPL-EDA Manual
│   └── SPL-G1 Alignment Matrix.pdf    # Material / compiler / chip three-layer causal alignment proof
├── outputs/                # Generated netlists
├── README.md
├── Materica-specification  # Cross-material causal mapping specification
├── SPL-Core.json           # Instruction set (11 opcodes incl. COMPUTE)
└── State_Anchor.pdl        # State anchor protocol (256-bit synthetic identity + 64-cycle verification)
```

> Quick start: `python eda_cli.py --desc examples/full_pipeline_demo.json --pdk pdk/silicon_cim_v1.json --strategy min_power --output outputs/netlist.json`

---

## 0x01 Overview

**SPL‑G1** is an experimental general‑purpose heterogeneous processor architecture built around the **SPL‑Core (Second‑Perspective Logic)** execution paradigm. It delivers a true **4‑in‑1 unified compute fabric** that integrates:

* **CPU-style** scalar processing (Instruction Fetch)
* **GPU-class** parallel rendering (SIMD Parallelism)
* **NPU-optimized** neural inference (Trustworthy AI)
* **In-fabric** state storage (Persistent Memory)

Designed for persistent virtual worlds, causal reasoning, and edge-grade intelligent systems, SPL‑G1 redefines computation as **traceable, auditable state evolution**, rather than inefficient, power‑hungry data shuffling.

---

## 0x02 Core Architectural Philosophy

1.  **Ultra‑Low‑Power by Architecture**: Eliminates unnecessary off‑fabric data transfer. Data movement is minimized by executing computation where the state resides.
2.  **Truly Unified General‑Purpose Substrate**: No more heterogeneous silos. Scalar logic, parallel throughput, tensor inference, and persistent state coexist in one execution model.
3.  **Deterministic, Auditable State by Hardware**: Every computation is anchored, traceable, and causally consistent at the hardware level via the **RA-BUS (Responsibility Anchoring Bus)**.

---

## 0x03 Cross‑Material Adaptation Protocol (CMAP)
*Decoupling Logic from Silicon*

The SPL‑G1 architecture is defined by its **Causal Topology**, not its material substrate. The CMAP specifies the requirements for mapping G1 logic onto non-silicon physical carriers:

* **Binary Stability ($P \to Q$)**: The material must support a stable physical mapping of binary states, ensuring transitions are resistant to stochastic "Narrative Noise."
* **Causal Topological Constraints**: Signal conduction must be directional and controlled under the **RA-BUS** causality spine, rather than relying on isotropic diffusion.
* **Proximal Physical Coalescence**: Computing and storage units must be physically proximate (or overlapping) at the atomic level to eliminate data-transport energy overhead ($\Delta E_{transport} \approx 0$).
* **Irreversible Security Boundaries**: Safety boundaries (SBC) must be enforced by **irreversible physical properties** (e.g., unidirectional photonic isolators or semi-permeable molecular barriers) to ensure hardware-level tamper resistance.

> **Applicable Materials**: Carbon Nanotubes (CNT), Photonic Crystals, Spintronic Arrays, and Synthetic Bio-Logic (DNA/Protein).

---

## 0x04 SPL‑Core Execution Paradigm

SPL‑G1 replaces the classic von Neumann bottleneck with a hardware-native state-driven cycle:

**`ANCHOR` → `EVOLVE` → `AUDIT` → `STRIP`**

* **Narrative Stripping (NSM)**: Extracts formal logic from semantic/narrative noise.
* **Implicit Assumption Detection (IAP)**: Hardware-level validation of (P → Q) premises.
* **Responsibility Anchoring**: Traceable weights and logic decision points.
* **Vulnerability Hedging**: Probability-based collapse detection for critical logic chains.

---

## 0x05 Project Status & Scope

* **Stage**: Architectural specification with functional RTL pipeline (v0.2.0).
* **Focus**: Causal-audit pipeline (NS→IAP→AUDIT→STRIP), compute core integration, cross-material PDK.
* **Hardware Identity Anchor**: `0x8525d007_59a4ca22`

**Scope of this repository:**
- SPL-Core instruction set (11 opcodes incl. COMPUTE)
- RTL: compute core (`g1_compute_core.sv`), causal audit pipeline (`spl_cim_causal_unit.sv`), top-level integration (`G1_Top_Interface.v`)
- EDA toolchain: causal description parser, multi-strategy PDK mapper, netlist/report exporter
- PDK: silicon CIM 28nm, optical MZI photonics (placeholder)
- Formal specification (Materica, State Anchor PDL)

---

## Contact

- **International / Global**: [ai@nohnlins.com](mailto:ai@nohnlins.com)
- **China**: [ai@tx.nohnlins.com](mailto:ai@tx.nohnlins.com)

---

## Licensing & Authorization

This repository is a technical showcase for **SPL-G1 General-purpose Processor**. Copyright © 2026 Shanghai Linming Junhua Technology Co., Ltd. and NOHN AI TECHNOLOGY PTE. LTD. All rights reserved.

| User | Purpose | License Requirement |
|---|---|---|
| Individual (natural person) | Non-commercial academic research / study / personal experimentation | **Free** under the "Free Individual Research License" in [LICENSE](./LICENSE) |
| Government agency / public institution / enterprise | Any purpose (incl. internal deployment, product development, service provision) | **Requires prior written paid authorization** |

- **Individual researchers** may use the Work free of charge for non-commercial research under [LICENSE](./LICENSE), but not for any commercial purpose, nor to provide services to any enterprise or government organization.
- **Government / enterprise users** may not copy, deploy, run, integrate, or distribute the Work before signing a Commercial Authorization Agreement and paying the agreed fee.
- **Apply for authorization**:
  - International / Global: [ai@nohnlins.com](mailto:ai@nohnlins.com)
  - China: [ai@tx.nohnlins.com](mailto:ai@tx.nohnlins.com)

The licensor, governing law, and dispute resolution are determined by the user's location as set out in [LICENSE](./LICENSE): users within the PRC → Shanghai Linming Junhua Technology Co., Ltd. (laws of the PRC); users outside the PRC → NOHN AI TECHNOLOGY PTE. LTD. (laws of Singapore, SIAC arbitration).
