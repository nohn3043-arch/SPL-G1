# SPL-G1 Phase 3 & 4 — RA-BUS Integration + EDA↔RTL Bridge

**Date:** 2026-07-24
**Status:** ✅ PHASE 3 COMPLETE · ✅ PHASE 4 COMPLETE

---

## Phase 3 — RA-BUS Bus Protocol

### What was built

| File | Type | Description |
|------|------|-------------|
| `rtl/ra_bus_arbiter.sv` | New | 4-target address decoder + arbiter. Targets: 0=PIM, 1=Audit, 2=Identity, 3=Reserved |
| `docs/ra_bus_protocol.md` | New | Complete protocol spec: signals, address map, READ/WRITE/EXECUTE/CONFIG timing |
| `rtl/G1_Top_Integrated.sv` | New | Full integrated top: Arbiter + PIM Sequencer + PIM Array + Audit Array + Identity Anchor |
| `rtl/tb_G1_Integrated.sv` | New | 5-test integration testbench via RA-BUS transactions |

### RA-BUS Address Map

```
0x0_xxxxxxx  → PIM Compute Array (256 MiB window)
0x1_xxxxxxx  → Causal Audit Array (4-unit status readback)
0x2_xxxxxxx  → Identity Anchor (hash nibble feed)
0x3_xxxxxxx  → Reserved / External expansion (stub)
```

### Simulation: 0 errors

```
[PASS] Identity anchor verified (64-cycle hash)
[INFO] SCALAR 42→55 pipeline exercised
[INFO] VECTOR column 0 ADD+5 exercised
[INFO] MATRIX ADD+1 exercised
===== Results: 0 errors =====
[FINAL] ALL TESTS PASSED. G1_Top_Integrated functional.
```

### Key fix: address decode bit position

- **Bug**: `0x20000000` → target_sel=`ra_addr[31:30]`=2'd0 (wrong: PIM)
- **Fix**: `ra_addr[29:28]` → target_sel=2'd2 (correct: Identity Anchor)

---

## Phase 4 — EDA Toolchain ↔ RTL Bridge

### What was built

| File | Type | Description |
|------|------|-------------|
| `eda_rtlgen.py` | New | RTL generator: maps CausalIR→spl_config_pkg.sv + tb_stimulus.sv + syn_tcl.tcl |
| `rtl/spl_pim_compute_array.sv` | Modified | Added `pim_ready`/`pim_resp` handshake ports for RA-BUS arbiter |
| `rtl/tb_pim_compute_array.sv` | Modified | Updated to match new PIM array ports |

### EDA pipeline now covers:

```
因果设计 JSON → CausalIR → PDK映射 → 工艺网表JSON
                             └→ spl_config_pkg.sv   (配置参数包)
                             └→ tb_stimulus.sv       (auto testbench)
                             └→ syn_tcl.tcl          (Yosys综合脚本)
```

### eda_rtlgen.py artifacts

- **spl_config_pkg.sv**: Design metadata + constraint params + per-op cell params (delay/power/area/SNR)
- **tb_stimulus.sv**: One task per CausalIR op, plus `tb_stimulus_run()` top-level runner
- **syn_tcl.tcl**: Yosys-compatible synthesis script (read_sv → hierarchy → proc → techmap → write_json/v)

---

## Consolidated RTL File Inventory

```
rtl/
├── G1_Top_Interface.v          # Original top (legacy, SBC-only)
├── G1_Top_Integrated.sv        # ← NEW: full RA-BUS integrated top
├── ra_bus_arbiter.sv           # ← NEW: 4-target bus arbiter
├── g1_compute_core.sv         # Original compute core
├── spl_cim_causal_unit.sv     # Original causal audit unit
├── spl_pim_cell.sv             # Phase 2: single PIM cell
├── spl_pim_compute_array.sv    # Phase 2: 4×4 array (updated handshake)
├── spl_pim_sequencer.sv       # Phase 2: 16-entry micro-op sequencer
├── tb_G1_Top.sv               # Original 4-test top-level tb
├── tb_pim_compute_array.sv    # Phase 2: PIM array tb (updated)
└── tb_G1_Integrated.sv        # ← NEW: full integration tb
```

## Known limitations (deferred to future work)

- External memory interface (target 3) is a stub
- RA-BUS lacks readback (no READ transactions implemented in sequencer)
- No formal timing constraints (SDC file)
- Array size fixed at 4×4
