# SPL-G1 Phase 2 — PIM Compute Array Complete

**Date:** 2026-07-24
**Status:** ✅ ALL TESTS PASSED

## What was built

| File | Type | Description |
|------|------|-------------|
| `rtl/spl_pim_cell.sv` | New | Single PIM compute cell: 64-bit latch store + 8-op ALU (ADD/SUB/MUL/CMP/SHIFT/XOR/NOP) + north/south/east/west neighbour interconnects + pim_store_en read-vs-write guard |
| `rtl/spl_pim_compute_array.sv` | New | 4×4 grid of pim_cell instances, addressable via RA-BUS, with SCALAR/VECTOR/MATRIX execution modes, per-column vec_sum, full-array mat_total |
| `rtl/spl_pim_sequencer.sv` | New | 16-entry micro-op instruction table (CONFIG-writable), drives pim_compute_array with programmable sequences |
| `rtl/tb_pim_compute_array.sv` | New | 3-test harness: SCALAR (10 ops: ADD/SUB/MUL/CMP/XOR/SHIFT), VECTOR (column-wide parallel), MATRIX (4×4 grid activation) |

## Simulation results (iverilog 12.0)

```
Test 1: SCALAR Arithmetic — 11/11 sub-tests PASSED
  - ADD 42+13=55, SUB 55-20=35, MUL 35*3=105, CMP, XOR 100^255=155
  - Read-back without side-effect verified

Test 2: VECTOR (column-wide) — 8/8 sub-tests PASSED
  - Column 0 cells (10,20,30,40) all +5 → (15,25,35,45) ✓

Test 3: MATRIX (full grid) — 22/22 sub-tests PASSED
  - 16 cells each loaded (r*10+c*5), +1 → 1..46
  - mat_total=376 ✓ (matches expected 240+120+16)
  - All 16 P-causal tags non-zero ✓

TOTAL: 0 errors
```

## Design decisions

- **pim_store_en guard**: Without it, SCALAR "read" NOP would overwrite cell with 0. Now pim_store_en=0 means read-only, =1 means execute+store.
- **Explicit 4×4 vec_sum/mat_total**: iverilog doesn't support `for(int...)` in `always_comb`, so accumulators are hand-written.
- **Neighbour interconnects wired but not yet tested**: Vertical/horizontal ripple paths exist in RTL; test coverage deferred to Phase 3 (RA-BUS integration).

## Known limitations

- Array currently fixed at 4×4; parameterized but synthesis not tested
- Sequencer not yet integrated into top-level testbench
- pim_store_en exposed as cell-level signal vs encoded in ra_op
