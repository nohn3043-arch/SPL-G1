# SPL-G1 Improvement Plan: PIM Unified-Compute General-Purpose Processor

> Version 1.0 — 2026-07-24
> Authoritative architecture roadmap derived from NOMOS + SPL-G1 co-design audit.

---

## 0. Design Thesis

**One compute paradigm — Processing-In-Memory (PIM) — achieves CPU/GPU/NPU equivalence
on the same physical cell grid via mode switching (SCALAR / VECTOR / MATRIX).
No traditional DRAM. External storage is persistent (NVMe/CXL), not working memory.**

---

## 1. Current State Diagnosis

```
E1 (direction correct): PIM grid + SCALAR/VECTOR/MATRIX = single paradigm ✓
E2 (7 critical gaps):
    A. Cell capability insufficient: 8 op, no branch, no FP, 1-bit neighbor
    B. Scale inadequate: 4×4 = 16 cells (demo, not processor)
    C. No control flow: Sequencer = 16-entry linear microcode, no JMP/loop/cond
    D. Storage interface vacuum: RA-BUS target 3 = 0xDEAD_BEEF stub
    E. Audit semantics fake: spl_cim_causal_unit uses magic numbers, NOMOS not connected
    F. Programming model absent: no compilable ISA, no mappable toolchain
    G. Non-parameterizable: vec_sum/mat_total hardcoded to 4 rows
```

---

## 2. Cell Architecture Upgrade (Gap A)

### 2.1 ALU Extension: 8 op → 32 op

| Opcode | Mnemonic | Description |
|--------|----------|-------------|
| 0x00 | NOP | No operation (passthrough) |
| 0x01 | ADD | local + input |
| 0x02 | ADC | ADD with carry-in (chainable for wide arithmetic) |
| 0x03 | SUB | local - input |
| 0x04 | SBB | SUB with borrow |
| 0x05 | MUL_LO | Multiply, low 64 bits |
| 0x06 | MUL_HI | Multiply, high 64 bits (→ 128-bit composition) |
| 0x07 | MAC | Multiply-accumulate: local + (local × input) |
| 0x08 | CMP_EQ | Equality compare → {63'b0, eq} |
| 0x09 | CMP_NE | Not-equal |
| 0x0A | CMP_LT | Signed less-than |
| 0x0B | CMP_GT | Signed greater-than |
| 0x0C | SHL | Shift left logical |
| 0x0D | SHR | Shift right logical |
| 0x0E | SAR | Shift right arithmetic |
| 0x0F | AND | Bitwise AND |
| 0x10 | OR | Bitwise OR |
| 0x11 | XOR | Bitwise XOR |
| 0x12 | NOT | Bitwise NOT (ignore ra_data_in) |
| 0x13 | FP16_ADD | Half-precision float add |
| 0x14 | FP16_SUB | FP16 subtract |
| 0x15 | FP16_MUL | FP16 multiply |
| 0x16 | FP16_CMP | FP16 equality |
| 0x17 | FP16_MAC | FP16 multiply-accumulate |
| 0x18 | PRED_SET | Set predicate register from CMP result |
| 0x19 | LOAD_ROW | Load from row-neighbour bus (8-bit wide) |
| 0x1A | LOAD_COL | Load from column-neighbour bus |
| 0x1B | STORE_LOCAL | Force-write to local_store (bypasses pim_store_en) |
| 0x1C-0x1F | RESERVED | Future: BF16, transcendental, crypto |

### 2.2 New Ports

```systemverilog
// Predicate execution
input  logic        pred_en;        // 1 = use predicate for conditional exec
output logic        pred_reg;       // predicate register (set by CMP ops)

// Wide neighbour interconnect (replaces 1-bit)
input  logic [7:0]  row_data_in;    // data from north neighbour
output logic [7:0]  row_data_out;   // data to south neighbour
input  logic [7:0]  col_data_in;    // data from west neighbour
output logic [7:0]  col_data_out;   // data to east neighbour
```

### 2.3 Implementation: `rtl/spl_pim_cell_v2.sv`

See companion file. Backward-compatible with existing `spl_pim_cell` interface
(1-bit neighbour wires tie to bit[0]; pred_en grounded).

---

## 3. Scale Model & Parameterization (Gaps B + G)

### 3.1 Hierarchical Tiling

| Level | Dimensions | Cells | Interconnect | Purpose |
|-------|-----------|-------|-------------|---------|
| Cell | 1×1 | 1 | — | Atomic compute-store unit |
| Tile | 16×16 | 256 | RA-BUS arbiter (4 targets) | Minimum functional unit |
| Block | 4×4 Tiles | 4,096 | 2D mesh of arbiters | Tape-out minimum |
| Chip | 8×8 Blocks | 262,144 | Hierarchical mesh + CXL | Production processor |

### 3.2 Parameterized Reduction Tree

Replace hardcoded `vec_sum[0] = cell[0][0] + cell[1][0] + cell[2][0] + cell[3][0]` with:

```systemverilog
module spl_pim_reduce_tree #(parameter int N = 16) (
    input  logic [63:0] values [N-1:0],
    output logic [63:0] total
);
    // O(log₂N) pipelined reduction
    // 16 inputs → 4 stages, 256 inputs → 8 stages
endmodule
```

### 3.3 RA-BUS Extension

```
Current: Single arbiter → 4 fixed targets
Phase 3:  Tile-internal RA-BUS (unchanged) +
          Tile-to-tile 2D mesh router (5 ports: N/S/E/W/LOCAL) +
          Chip-to-host CXL.io / PCIe Gen5
```

---

## 4. Control Flow & ISA (Gaps C + F)

### 4.1 SPL-G1 ISA v1.0 (32-bit fixed-length)

```
[31:28] opcode   [27:24] cond    [23:16] mode    [15:8] reg    [7:0] imm
```

| Opcode | Mnemonic | Description |
|--------|----------|-------------|
| 0x0 | LOAD_IMM | Load immediate to cell register |
| 0x1 | STORE | Write cell register to local_store |
| 0x2 | ALU_OP | Execute ALU operation (op from imm[4:0]) |
| 0x3 | BRANCH | Conditional jump (JMP/JZ/JNZ) |
| 0x4 | MOVE_CELL | Data movement between cells |
| 0x5 | AUDIT | Trigger causal audit check |
| 0x6 | BARRIER | Wait for all cells in tile |
| 0x7 | SYNC | Synchronization fence |
| 0x8 | LOAD_EXT | DMA load from external storage |
| 0x9 | STORE_EXT | DMA store to external storage |
| 0xA-0xF | RESERVED | |

**Key innovation**: `mode` field embedded in every instruction.
SCALAR → VECTOR → MATRIX switching per-instruction, not per-program.
This IS the "one paradigm = CPU+GPU+NPU" at the ISA level.

### 4.2 PPCU (PIM Program Counter Unit)

```
Upgrade spl_pim_sequencer → spl_ppcu:
  - 256-entry program store (CONFIG-writable)
  - JMP / JZ / JNZ (conditional on predicate register)
  - CALL / RET (4-deep return stack)
  - exec_mode per instruction (not per sequence)
  - BARRIER: stall until all cells in tile complete current op
```

---

## 5. Storage Interface (Gap D)

PIM principle: **cell.local_store IS working memory. No DRAM.**

External storage = persistent only (SSD, CXL Type-3 memory pool).

```
LOAD_EXT(addr, tile_row, tile_col, length):
    DMA engine reads from NVMe → writes to RA-BUS target 3 →
    data dispersed to specified tile region

STORE_EXT(addr, tile_row, tile_col, length):
    Reverse path: tile region → RA-BUS target 3 → DMA → NVMe write
```

### Implementation (Phase 3)

```
RA-BUS target 3 → AXI4-MM bridge → SimpleNVMe controller → FPGA NVMe IP / real SSD
```

Bandwidth target: ~2 GB/s (PCIe Gen3 ×2 equivalent), sufficient for 256-cell tile.

---

## 6. NOMOS Causal Audit Integration (Gap E)

### 6.1 Causal Record Wire Format (256-bit)

```
[255:248] rule_id          — NOMOS constraint rule hash prefix
[247:192] dep_mask         — 56-bit dependency bitmask (which premises)
[191:128] constraint_bits  — 64-bit hard-constraint pass bits (1=OK)
[127:64]  weight_q16_16    — weight / sensitivity (Q16.16 fixed-point)
[63:0]    provenance_lo    — provenance chain hash, low 64 bits
```

### 6.2 Audit Unit v2

```systemverilog
// Replaces magic-number detection (0xAAAA, 0xFF, 0xDE→0xAD)
// with NOMOS-derived constraint checking

logic constraint_pass = (causal_record[191:128] == 64'hFFFF_FFFF_FFFF_FFFF);
logic dep_valid = ((causal_record[247:192] & ~assumption_state[55:0]) == 56'h0);
logic logic_valid = constraint_pass && dep_valid;
```

### 6.3 NOMOS → PIM Pipeline

```
NOMOS engine.py  →  invalidation_closure  →  causal_record.json
    →  eda_mapper.py  →  RA-BUS CONFIG write to audit area
```

---

## 7. Programming Model & Toolchain (Gap F)

```
SPL-C (C subset with PIM annotations)
        │
    splcc compiler (3 passes)
    ┌───────────┴───────────┐
  Dataflow Graph        Control-Flow Graph
    │                       │
  grid_placer.py        seq_scheduler.py
    │                       │
  Cell placement map     PPCU instruction stream
    └───────────┬───────────┘
         SPL-G1 ISA binary
                │
         eda_rtlgen.py
                │
      config_pkg.sv + microcode table
```

### Compiler Mode Mapping

| Source Pattern | Compiler Recognition | PIM Mode |
|---------------|---------------------|----------|
| `for(i=0;i<N;i++) a[i] += b[i]` | Independent vector loop | VECTOR (column-parallel) |
| `C = A × B` (matmul) | Nested loop, reduction | MATRIX (full grid MAC) |
| `if(x>0) y=f(x) else y=g(x)` | Control flow, branch | SCALAR (predicated) |

---

## 8. Phased Roadmap

### Phase 1 — Foundation (2-3 weeks)
- [x] IMPROVEMENT_PLAN.md (this document)
- [ ] Cell v2: 32-op ALU + predicate + 8-bit neighbour (spl_pim_cell_v2.sv)
- [ ] Array parameterization: reduction tree, generate-based dims
- [ ] NOMOS causal_record wire format → spl_cim_causal_unit_v2
- [ ] Full iverilog test suite passes

### Phase 2 — Control Flow (2-3 weeks)
- [ ] PPCU: 256-entry program store + JMP/JZ/JNZ/CALL/RET
- [ ] Per-instruction mode field in microcode
- [ ] BARRIER synchronization primitive
- [ ] splcc compiler v0.1 (C subset → SPL-G1 ISA)

### Phase 3 — Scale & Storage (4-6 weeks)
- [ ] Tile 2D mesh interconnect (5-port router)
- [ ] AXI4-MM bridge + storage controller (RA-BUS target 3)
- [ ] Scale simulator (thousands of cells, behavioral)
- [ ] Yosys synthesis + area/power estimation

### Phase 4 — Tape-out Prep (8-12 weeks)
- [ ] Block-level (4096 cells) complete RTL
- [ ] Real PDK integration (SkyWater 130nm open-source)
- [ ] Place & route + timing closure
- [ ] CXL bridge (optional; fallback to AXI)

---

## 9. Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| 4096 cells exceeds area budget | Phase 4 blocked | Phase 3 synthesis first; downscale if needed |
| 8-bit neighbour bus power too high | VECTOR/MATRIX perf collapse | Power-gate idle rows/columns |
| PPCU BARRIER deadlock in distributed grid | Program hang | Timeout watchdog → tile reset |
| NOMOS rules > 256 | Bitmask overflow | Sharding: multi-pass per batch of 256 rules |

---

## 10. Compatibility Note

All v2 modules are created as NEW files alongside existing ones.
Existing testbench, EDA toolchain, and `G1_Top_Integrated` continue to work
with original `spl_pim_cell` until integration testing completes.

---

*Derived from formal co-design audit of NOMOS (IMDA AI Verify 95/100) + SPL-G1 RTL.*
*Decision authority: NOHN-AI. License: SPL-G1 dual-track.*
