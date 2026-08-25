"""
SP-EDA RTL Generator (v0.1.0)

Converts EDA mapping results into synthesizable RTL artifacts:
  1. spl_config_pkg.sv  — SystemVerilog config package from mapping results
  2. tb_stimulus.sv     — Auto-generated testbench stimulus from causal IR
  3. syn_tcl.tcl        — Yosys/DC synthesis TCL script skeleton

Usage:
  from eda_rtlgen import generate_rtl_artifacts

  artifacts = generate_rtl_artifacts(mapping_result, output_dir="outputs/rtlgen/")
  # writes output_dir/spl_config_pkg.sv, tb_stimulus.sv, syn_tcl.tcl
"""

import os
import re
from typing import List, Optional

from eda_mapper import MappingResult, OpMapping


# ═══════════════════════════════════════════════════════════════════
# Component 1: spl_config_pkg.sv
# ═══════════════════════════════════════════════════════════════════

# ── Causal op → PIM micro-op encoding (Stage 1/2: real dataflow) ──
# These map the 6 causal op classes to PIM micro-ops understood by
# spl_pim_cell / spl_pim_sequencer.
#
# v0.2.0: formal backend semantics (eda_backend.py). CAUSAL_OP_TO_MICRO is
# kept as the PRIMARY (lead) opcode of each op's micro-op SEQUENCE — the
# full per-op sequence + audit record generation now lives in eda_backend,
# and the generated spl_config_pkg carries both (see _generate_config_pkg).
from eda_backend import (
    OP_SEQUENCES,
    RULE_ID_MAP,
    CausalRecord,
    OPCODE_NAMES,
    build_causal_record,
    build_design_provenance,
    get_op_sequence,
    opcode_list_to_names,
    opcode_list_to_hex,
)

CAUSAL_OP_TO_MICRO = {
    "NS": OP_SEQUENCES["NS"]["seq"][0][0],
    "IAP": OP_SEQUENCES["IAP"]["seq"][0][0],
    "LCH": OP_SEQUENCES["LCH"]["seq"][0][0],
    "CCS": OP_SEQUENCES["CCS"]["seq"][0][0],
    "STATE": OP_SEQUENCES["STATE"]["seq"][0][0],
    "COMPUTE": OP_SEQUENCES["COMPUTE"]["seq"][0][0],
}

# ── RA-BUS cell addressing (from spl_pim_compute_array.sv) ──
#   cell(r,c) → ra_addr = (r << 24) | (c << 16),  target bits[29:28]=00
#   sequencer program entry → ra_addr[9:0]


def _generate_config_pkg(
    result: MappingResult, array_rows: int = 64, array_cols: int = 64, ir: object = None
) -> str:
    """Generate spl_config_pkg.sv from mapping results.

    This package is the EDA→RTL configuration hook (Stage 1):
    G1_Top_Integrated imports it and reads PIM_ROWS/PIM_COLS/MATERIAL.
    """
    lines = [
        "// ============================================================================",
        f"// spl_config_pkg — Auto-generated from EDA mapping: {result.design_name}",
        "// DO NOT EDIT MANUALLY — regenerate with: python eda_cli.py --rtl --apply-rtl",
        "// ============================================================================",
        "",
        "package spl_config_pkg;",
        "",
    ]

    # Design metadata
    lines.extend(
        [
            f"    // ── Design: {result.design_name} ──",
            f'    localparam string DESIGN_NAME = "{result.design_name}";',
            f'    localparam string MATERIAL    = "{result.material}";',
            f'    localparam string STRATEGY    = "{result.strategy}";',
            "",
            "    // ── Array geometry (EDA-driven; G1_Top reads these) ──",
            f"    localparam int    PIM_ROWS    = {array_rows};",
            f"    localparam int    PIM_COLS    = {array_cols};",
            "",
        ]
    )

    # Constraint parameters
    c = result.constraints
    if c.max_delay_ns is not None:
        lines.append(f"    localparam real   MAX_DELAY_NS = {c.max_delay_ns};")
    if c.max_power_mw is not None:
        lines.append(f"    localparam real   MAX_POWER_MW = {c.max_power_mw};")
    if c.max_area_um2 is not None:
        lines.append(f"    localparam real   MAX_AREA_UM2 = {c.max_area_um2};")
    if c.min_snr_db is not None:
        lines.append(f"    localparam real   MIN_SNR_DB   = {c.min_snr_db};")
    lines.append("")

    # Op type enum
    lines.append("    // ── Causal op type encoding ──")
    lines.append("    typedef enum logic [2:0] {")
    op_types = sorted(set(op.op_type for op in result.ops))
    for i, ot in enumerate(op_types):
        comma = "," if i != len(op_types) - 1 else ""
        safe_name = ot.replace("-", "_").replace(" ", "_").upper()
        lines.append(f"        OP_{safe_name} = 3'd{i}{comma}")
    lines.append("    } causal_op_type_t;")
    lines.append("")

    # Per-op config parameters
    lines.append("    // ── Op-specific configuration ──")
    for op in result.ops:
        safe = f"OP{op.op_index}"
        if op.selected:
            sel = op.selected
            cell = sel.implementation_spec.get("cell_type", "unknown")
            safe_cell = re.sub(r"[^A-Za-z0-9_]", "_", cell).upper()
            lines.extend(
                [
                    f"    //  [{op.op_index}] {op.op_type} → {cell}",
                    f'    localparam string {safe}_CELL     = "{cell}";',
                    f"    localparam real   {safe}_DELAY_NS = {sel.delay_ns};",
                    f"    localparam real   {safe}_POWER_MW = {sel.power_mw};",
                    f"    localparam real   {safe}_AREA_UM2 = {sel.area_um2};",
                    f"    localparam real   {safe}_SNR_DB   = {sel.snr_db};",
                ]
            )
            # Export implementation_spec as individual params
            for k, v in sel.implementation_spec.items():
                if isinstance(v, (int, float)):
                    safe_k = re.sub(r"[^A-Za-z0-9_]", "_", str(k)).upper()
                    lines.append(f"    localparam real   {safe}_{safe_k} = {v};")
        else:
            lines.extend(
                [
                    f"    //  [{op.op_index}] {op.op_type} — UNMAPPED: {op.failed_reason}",
                ]
            )
        lines.append("")

    # ════════════════════════════════════════════════════════════
    # Backend semantics block (v0.2.0) — micro-op sequences + audit records
    # ════════════════════════════════════════════════════════════
    # Derived from eda_backend.py; per-op microcode sequences match the
    # real spl_pim_cell.v2 opcode table, and each causal record matches
    # the spl_cim_causal_unit.v2 wr_data_p/wr_data_q wire format.
    lines.append("    // ════════════════════════════════════════════════════════════")
    lines.append(
        "    // ── Backend semantics (v0.2.0): micro-op sequences + audit records ──"
    )
    lines.append("    // ════════════════════════════════════════════════════════════")

    # Producer map: signal → op_index (for dependency mask construction)
    producer_of: dict = {}
    if ir is not None and hasattr(ir, "ops"):
        for _i, _op in enumerate(ir.ops):
            for _out in _op.outputs:
                producer_of[_out] = _i

    design_hash = build_design_provenance(result.design_name)

    for op in result.ops:
        safe = f"OP{op.op_index}"
        op_key = str(op.op_type).upper()
        # 1) micro-op sequence (lead opcode + full sequence)
        seq_desc, seq_opcodes = get_op_sequence(op_key)
        lead = seq_opcodes[0] if seq_opcodes else 0x00
        seq_hex = opcode_list_to_hex(seq_opcodes)
        seq_names = opcode_list_to_names(seq_opcodes)
        lines.extend(
            [
                f"    //  [{op.op_index}] {op_key} backend sequence ({seq_desc})",
                f"    localparam logic [4:0] {safe}_MICRO_OP   = 5'h{lead:02X};  // lead opcode",
                f'    localparam string {safe}_MICRO_SEQ  = "{seq_names}";',
                f'    localparam string {safe}_MICRO_HEX  = "{seq_hex}";',
            ]
        )
        # 2) audit record (Causal Record → spl_cim_causal_unit v2)
        #    producer indices from the IR dataflow
        prod_idx: List[int] = []
        if ir is not None and hasattr(ir, "ops"):
            op_i = op.op_index
            if 0 <= op_i < len(ir.ops):
                for _inp in ir.ops[op_i].inputs:
                    if _inp in producer_of:
                        prod_idx.append(producer_of[_inp])
        rec = build_causal_record(
            op_key,
            op.op_index,
            prod_idx,
            design_hash=design_hash,
        )
        rec_p = rec.pack_p()
        rec_q = rec.pack_q()
        lines.extend(
            [
                f"    //  audit record: rule={rec.rule_id:#04x} dep_mask={rec.dep_mask:014x} "
                f"weight_q16_16={rec.weight_q16_16:#x}",
                f"    localparam logic [255:0] {safe}_AUDIT_P = 256'h{rec_p:064x};",
                f"    localparam logic [255:0] {safe}_AUDIT_Q = 256'h{rec_q:064x};",
            ]
        )
        lines.append("")

    lines.extend(["endpackage", ""])
    return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════
# Component 2: tb_stimulus.sv
# ═══════════════════════════════════════════════════════════════════


def _sanitize_identifier(s: str) -> str:
    """Sanitize a string into a valid Verilog identifier."""
    return re.sub(r"[^A-Za-z0-9_]", "_", s)


def _generate_tb_stimulus(
    result: MappingResult, array_rows: int = 64, array_cols: int = 64, ir: object = None
) -> str:
    """Generate a SYSTEMVERILOG TESTBENCH driving the REAL PIM array.

    Stage 1 (缝2 打通): stimulus is no longer a hardcoded MUL@cell(0,0)
    placeholder. Each causal IR op gets:
      - a real cell assignment (row-major over the array geometry)
      - a micro-op from CAUSAL_OP_TO_MICRO
      - a sequencer program entry (CONFIG) + EXECUTE, mirroring the
        exact RA-BUS protocol of tb_G1_Integrated (ra_config/ra_execute).
    The generated file is a standalone testbench that compiles and runs
    against the RTL (iverilog), so EDA output is directly verifiable.

    Stage 2 (dataflow real): per-op execution reads back predecessor
    cells via RA-BUS READ (ra_cmd=00) into a signal-value array, then
    passes the first predecessor value into the destination cell —
    a real readback-pass-execute sequence over the causal graph edges.
    """
    lines = [
        "// ============================================================================",
        f"// tb_eda_stimulus — Auto-generated from EDA mapping: {result.design_name}",
        "// DO NOT EDIT MANUALLY — regenerate with: python eda_cli.py --rtl",
        "// ============================================================================",
        "// Stage 1: real dataflow stimulus. Each causal IR op drives the",
        "// actual PIM array via the RA-BUS protocol (CONFIG entry + EXECUTE).",
        "//",
        "// Compile:",
        "//   iverilog -g2012 -o g1_sim rtl/G1_Top_Integrated.sv \\",
        "//     rtl/ra_bus_arbiter.sv rtl/spl_pim_sequencer.sv rtl/spl_pim_cell.sv \\",
        "//     rtl/spl_pim_compute_array.sv rtl/spl_cim_causal_unit.sv \\",
        "//     rtl/ext_mem_controller.sv rtl/materica_compliance_unit.sv \\",
        f"//     <this file>",
        "// ============================================================================",
        "",
        "`timescale 1ns / 1ps",
        "",
        "module tb_eda_stimulus;",
        "",
        "    localparam int DATA_W = 128;",
        "",
        "    logic        clk, rst_n;",
        "    logic        ra_valid;",
        "    logic [ 1:0] ra_cmd;",
        "    logic [31:0] ra_addr;",
        "    logic [DATA_W-1:0] ra_wdata;",
        "    logic [DATA_W-1:0] ra_rdata;",
        "    logic        ra_ready;",
        "    logic [ 1:0] ra_resp;",
        "    logic [255:0] hw_hash;",
        "    logic        pim_state_stable;",
        "    logic        logic_integrity_verified;",
        "    logic        fuse_blown;",
        "",
        "    G1_Top_Integrated #(.DATA_W(DATA_W)) dut (",
        "        .clk, .rst_n,",
        "        .ra_valid, .ra_cmd, .ra_addr, .ra_wdata,",
        "        .ra_rdata, .ra_ready, .ra_resp,",
        "        .hardware_hash_in(hw_hash),",
        "        .pim_state_stable, .logic_integrity_verified,",
        "        .fuse_blown",
        "    );",
        "",
        "    initial clk = 1'b0;",
        "    always #5 clk = ~clk;",
        "",
        "    // ── RA-BUS helpers (same protocol as tb_G1_Integrated) ──",
        "    task ra_tick;",
        "        begin @(posedge clk); #1; end",
        "    endtask",
        "",
        "    task ra_write;",
        "        input [31:0] addr; input [63:0] data;",
        "        begin",
        "            @(negedge clk);",
        "            ra_valid=1; ra_cmd=2'b01; ra_addr=addr; ra_wdata=data;",
        "            ra_tick;",
        "            @(negedge clk);",
        "            ra_valid=0; ra_wdata=64'h0;",
        "        end",
        "    endtask",
        "",
        "    task ra_config;",
        "        input [31:0] addr; input [63:0] data;",
        "        begin",
        "            @(negedge clk);",
        "            ra_valid=1; ra_cmd=2'b11; ra_addr=addr; ra_wdata=data;",
        "            ra_tick;",
        "            @(negedge clk);",
        "            ra_valid=0;",
        "        end",
        "    endtask",
        "",
        "    task ra_execute;",
        "        input [31:0] addr; input [63:0] data;",
        "        begin",
        "            @(negedge clk);",
        "            ra_valid=1; ra_cmd=2'b10; ra_addr=addr; ra_wdata=data;",
        "            ra_tick;",
        "            @(negedge clk);",
        "            ra_valid=0;",
        "        end",
        "    endtask",
        "",
        "    // ── RA-BUS READ (ra_cmd=00) — sequencer SEQ_READ path ──",
        "    task ra_read;",
        "        input [31:0] addr;",
        "        begin",
        "            @(negedge clk);",
        "            ra_valid=1; ra_cmd=2'b00; ra_addr=addr; ra_wdata=64'h0;",
        "            ra_tick;",
        "            repeat(2) @(posedge clk);",
        "            @(negedge clk);",
        "            ra_valid=0;",
        "        end",
        "    endtask",
        "",
        "    integer errors;",
        "",
        "    // ── Dataflow signal-value shadow registers (Stage 2) ──",
        "    // One entry per causal signal; read back from predecessor cells.",
        "    logic [DATA_W-1:0] sig_val [0:__SIG_NUM__-1];",
        "",
        "    initial begin",
        "        errors = 0;",
        "        ra_valid=0; ra_cmd=0; ra_addr=0; ra_wdata=0; hw_hash=256'h0;",
        "        rst_n=0; #50; rst_n=1; #20;",
        "",
        f'        $display("===== EDA Stimulus: {result.design_name} =====");',
        f'        $display("Material: {result.material} | Strategy: {result.strategy}");',
        f'        $display("Total ops: {len(result.ops)} | Mapped: {sum(1 for o in result.ops if o.selected)}");',
        "",
    ]

    # ── Stage 2: dataflow-aware cell allocation + readback-pass-execute plan ──
    if ir is None:
        # Fallback: synthesize a minimal CausalIR from result.ops so the
        # dataflow module still works when no IR object is available.
        from EDA_fixed import CausalIR, CausalOp

        ir_obj = CausalIR(
            name=result.design_name,
            inputs=list(result.ops[0].inputs) if result.ops else [],
            outputs=list(result.ops[-1].outputs) if result.ops else [],
            ops=[
                CausalOp(op_type=op.op_type, inputs=op.inputs, outputs=op.outputs)
                for op in result.ops
            ],
        )
    else:
        ir_obj = ir

    from eda_dataflow import allocate_cells, build_exec_plan

    alloc = allocate_cells(ir_obj, array_cols)
    cell_names = {
        i: (
            op.selected.implementation_spec.get("cell_type", "?")
            if op.selected
            else "UNMAPPED"
        )
        for i, op in enumerate(result.ops)
    }
    plan = build_exec_plan(ir_obj, alloc, cell_names)

    # Signal → sig_val index (stable mapping over all produced signals)
    sig_index: dict = {}
    next_idx = 0
    for op in ir_obj.ops:
        for out in op.outputs:
            if out not in sig_index:
                sig_index[out] = next_idx
                next_idx += 1
    sig_num = max(next_idx, 1)

    for step in plan:
        op_index = step.op_index
        op = result.ops[op_index]
        micro = step.micro_op
        dr, dc = step.dst_cell
        dst_addr = f"32'h{dr:02X}{dc:02X}0000"
        src_desc = (
            ", ".join(f"cell({r},{c})←{name}" for name, r, c in step.src_cells)
            or "none (external)"
        )
        if op.selected:
            cell = op.selected.implementation_spec.get("cell_type", "?")
            lines.extend(
                [
                    f"        // ── [{op_index}] {op.op_type}: ({', '.join(op.inputs)}) → ({', '.join(op.outputs)}) ──",
                    f"        // mapped to {cell} (delay={op.selected.delay_ns}ns, power={op.selected.power_mw}mW)",
                    f"        // micro-op 0x{micro:02X} @ cell({dr},{dc}) | sources: {src_desc}",
                    f"        ra_config(32'h{op_index:08X}, {{40'h0, 8'd1, 8'h{micro:02X}, 6'h0, 2'b01}});",
                ]
            )
            # Real dataflow: read back every predecessor cell via RA-BUS READ
            if step.src_cells:
                for name, sr, sc in step.src_cells:
                    if name in sig_index:
                        lines.append(
                            f"        ra_read(32'h{sr:02X}{sc:02X}0000);  // read back {name}"
                        )
                        lines.append(f"        sig_val[{sig_index[name]}] = ra_rdata;")
                sname, sr, sc = step.src_cells[0]
                if sname in sig_index:
                    lines.append(
                        f"        ra_execute({dst_addr}, sig_val[{sig_index[sname]}]);  // pass {sname} → {op.op_type}"
                    )
            else:
                lines.append(
                    f"        ra_execute({dst_addr}, 64'd{op_index});  // external input"
                )
            lines.append(f"        repeat(4) @(posedge clk);")
            lines.append("")
        else:
            lines.extend(
                [
                    f"        // [{op_index}] {op.op_type} UNMAPPED — skipped (reason: {op.failed_reason})",
                    "",
                ]
            )

    # Inject the actual signal count into the sig_val declaration
    lines_str = "\n".join(lines)
    lines_str = lines_str.replace("__SIG_NUM__", str(sig_num))
    lines = lines_str.split("\n")

    lines.extend(
        [
            "        // ── Audit pipeline settles ──",
            "        repeat(40) @(posedge clk);",
            "",
            "        if (fuse_blown === 1'b0 && pim_state_stable === 1'b1)",
            '            $display("[PASS] EDA stimulus completed: array stable, fuse intact");',
            "        else begin",
            '            $display("[FAIL] fuse_blown=%b pim_state_stable=%b", fuse_blown, pim_state_stable);',
            "            errors = errors + 1;",
            "        end",
            "",
            '        $display("===== Results: %0d errors =====", errors);',
            "        $finish;",
            "    end",
            "",
            "endmodule",
        ]
    )
    return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════
# Component 3: syn_tcl.tcl (Yosys-compatible synthesis script)
# ═══════════════════════════════════════════════════════════════════


def _generate_syn_tcl(
    result: MappingResult,
    top_module: str = "G1_Top_Integrated",
    rtl_dir: str = "rtl",
    config_pkg_dir: str = "outputs/rtlgen",
) -> str:
    """Generate a complete, runnable Yosys synthesis script.

    v0.2.0 upgrades:
      - Fixed read_sv -> read_verilog -sv (Yosys does not have read_sv)
      - Config pkg read from config_pkg_dir (where it is actually generated)
      - Full synthesis flow: proc -> opt -> fsm -> memory -> techmap -> abc -> opt_clean
      - Comprehensive reports via tee (gate count, area, wire count)
      - Multiple netlist output formats (Verilog, JSON, EDIF)
      - Optional SDC timing analysis section
      - Proper exclusion of ALL testbench files from synthesis
    """
    design = _sanitize_identifier(result.design_name)
    cfg_dir = config_pkg_dir.rstrip("/")
    lines = [
        "# ============================================================================",
        f"# Yosys synthesis script - Auto-generated from EDA mapping: {result.design_name}",
        "# DO NOT EDIT MANUALLY - regenerate with: python eda_cli.py --rtl",
        "#",
        f"# Usage: yosys -c syn_{design}.tcl",
        "# Prerequisites:",
        f"#   - RTL files in {rtl_dir}/",
        f"#   - Generated spl_config_pkg.sv in {cfg_dir}/",
        "# Output:",
        f"#   outputs/{result.design_name}_syn.v       - Verilog gate-level netlist",
        f"#   outputs/{result.design_name}_syn.json    - JSON netlist",
        f"#   outputs/{result.design_name}_syn.edif    - EDIF netlist (FPGA tools)",
        f"#   outputs/{result.design_name}_syn_rpt.txt - Synthesis report",
        "# ============================================================================",
        "",
        "# -- Step 1: Read design (EDA-generated config package FIRST) --",
        f"read_verilog -sv {cfg_dir}/spl_config_pkg.sv",
        "",
        f"# -- Discover and read RTL files from {rtl_dir}/ --",
        f"set rtl_files [glob -nocomplain {rtl_dir}/*.sv]",
        "",
        "# Exclude testbenches and already-read config package",
        f"set exclude_patterns [list {rtl_dir}/spl_config_pkg.sv {rtl_dir}/tb_eda_stimulus.sv {rtl_dir}/tb_G1_Integrated.sv {rtl_dir}/tb_G1_Top.sv {rtl_dir}/tb_cell_v2.sv {rtl_dir}/tb_pim_compute_array.sv {rtl_dir}/tb_materica_compliance.sv]",
        "foreach excl $exclude_patterns {",
        "    set rtl_files [lsearch -all -inline -not -exact $rtl_files $excl]",
        "}",
        "foreach f $rtl_files {",
        "    read_verilog -sv $f",
        "}",
        "",
        f"# -- Step 2: Hierarchy and elaboration --",
        f"hierarchy -top {top_module}",
        "",
        "# -- Step 3: Synthesis flow --",
        "# Translate processes (always blocks)",
        "proc",
        "# Initial optimization pass",
        "opt",
        "# FSM detection and optimization",
        "fsm",
        "# FSM re-encode + optimize",
        "fsm -recode",
        "opt",
        "# Memory inference and tech mapping",
        "memory",
        "opt",
        "# Technology mapping (generic gates)",
        "techmap",
        "# Post-techmap optimization",
        "opt -fast",
        "# ABC-based combinational logic optimization (generic, no liberty file)",
        "abc -fast",
        "# Final cleanup",
        "opt_clean",
        "",
        f"# -- Step 4: Reports --",
        f"# Statistics: gate count, area estimate, wire count, cell breakdown",
        f"tee -o outputs/{result.design_name}_syn_rpt.txt stat -top {top_module}",
        "",
        "# Detailed cell type count",
        "select -count t:*",
        "",
        f"# -- Step 5: Write netlists --",
        f"write_verilog -noattr outputs/{result.design_name}_syn.v",
        f"write_json outputs/{result.design_name}_syn.json",
        f"write_edif outputs/{result.design_name}_syn.edif",
        "",
        f"# -- Step 6: Optional timing analysis (uncomment when SDC available) --",
        "# read_sdc constraints/g1_timing.sdc",
        "# sta",
        "",
        f"# -- Synthesis complete for {result.design_name} --",
    ]
    return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════
# Component 4: causal_assertions.sv (SVA formal verification)
# ═══════════════════════════════════════════════════════════════════


def _generate_sva_assertions(
    result: MappingResult,
    array_rows: int = 64,
    array_cols: int = 64,
    ir: object = None,
) -> str:
    """Generate SystemVerilog Assertions from causal IR and mapping results.

    Produces a standalone SVA module that can be instantiated alongside
    G1_Top_Integrated to verify:
      1. RA-BUS valid-ready handshake protocol
      2. Per-op cell configuration (micro-op matches expected lead opcode)
      3. Fuse integrity (no fuse blow under normal operation)
      4. State stability (pim_state_stable asserted after operations)
      5. Op type coverage (each causal op type is configured and executed)

    The module is bindable -- instantiate it in the testbench and connect
    the same signals as the DUT.
    """
    # Get IR (same fallback as _generate_tb_stimulus)
    if ir is None:
        from EDA_fixed import CausalIR, CausalOp

        ir_obj = CausalIR(
            name=result.design_name,
            inputs=list(result.ops[0].inputs) if result.ops else [],
            outputs=list(result.ops[-1].outputs) if result.ops else [],
            ops=[
                CausalOp(op_type=op.op_type, inputs=op.inputs, outputs=op.outputs)
                for op in result.ops
            ],
        )
    else:
        ir_obj = ir

    from eda_dataflow import allocate_cells, build_exec_plan

    alloc = allocate_cells(ir_obj, array_cols)
    plan = build_exec_plan(ir_obj, alloc)

    lines = [
        "// ============================================================================",
        f"// causal_assertions - Auto-generated SVA from EDA mapping: {result.design_name}",
        "// DO NOT EDIT MANUALLY - regenerate with: python eda_cli.py --rtl",
        "//",
        "// Instantiate alongside G1_Top_Integrated in the testbench:",
        "//   causal_assertions #(.DATA_W(128)) sva_inst (.*);",
        "//",
        "// Compile: iverilog -g2012 -o sim rtl/*.sv <this_file> <testbench>",
        "// ============================================================================",
        "",
        "`timescale 1ns / 1ps",
        "",
        "module causal_assertions #(",
        "    parameter DATA_W = 128",
        ") (",
        "    input logic              clk,",
        "    input logic              rst_n,",
        "    // RA-BUS interface",
        "    input logic              ra_valid,",
        "    input logic [1:0]        ra_cmd,",
        "    input logic [31:0]       ra_addr,",
        "    input logic [DATA_W-1:0] ra_wdata,",
        "    input logic [DATA_W-1:0] ra_rdata,",
        "    input logic              ra_ready,",
        "    input logic [1:0]        ra_resp,",
        "    // DUT status outputs",
        "    input logic              pim_state_stable,",
        "    input logic              logic_integrity_verified,",
        "    input logic              fuse_blown",
        ");",
        "",
        "    // RA-BUS command encoding (from ra_bus_arbiter.sv)",
        "    localparam RA_READ    = 2'b00;",
        "    localparam RA_WRITE   = 2'b01;",
        "    localparam RA_EXECUTE = 2'b10;",
        "    localparam RA_CONFIG  = 2'b11;",
        "",
        "    // ====================================================================",
        "    // Assertion 1: RA-BUS valid-ready handshake",
        "    // When ra_valid is asserted, ra_ready must come within 16 cycles",
        "    // ====================================================================",
        "    property ra_handshake_valid_ready;",
        "        @(posedge clk) disable iff (!rst_n)",
        "        ra_valid |-> ##[0:15] ra_ready;",
        "    endproperty",
        "    assert property (ra_handshake_valid_ready)",
        '        else $error("[SVA FAIL] RA-BUS handshake: ra_valid without ra_ready within 16 cycles");',
        "",
        "    // ====================================================================",
        "    // Assertion 2: Fuse integrity under normal operation",
        "    // If no error response (ra_resp != 2'b10), fuse must not blow",
        "    // ====================================================================",
        "    property fuse_intact_no_violation;",
        "        @(posedge clk) disable iff (!rst_n)",
        "        (ra_valid && ra_resp != 2'b10) |-> ##1 fuse_blown == 1'b0;",
        "    endproperty",
        "    assert property (fuse_intact_no_violation)",
        '        else $error("[SVA FAIL] Fuse blown without violation response");',
        "",
        "    // ====================================================================",
        "    // Assertion 3: State stability after reset",
        "    // After reset deasserts, pim_state_stable must eventually be 1",
        "    // ====================================================================",
        "    property state_stable_after_reset;",
        "        @(posedge clk) disable iff (!rst_n)",
        "        ##100 pim_state_stable == 1'b1;",
        "    endproperty",
        "    assert property (state_stable_after_reset)",
        '        else $error("[SVA FAIL] PIM state not stable after 100 cycles post-reset");',
        "",
    ]

    # Per-op assertions: config opcode check + execution coverage
    lines.append(
        "    // ===================================================================="
    )
    lines.append(f"    // Per-op assertions ({len(plan)} ops)")
    lines.append(
        "    // ===================================================================="
    )
    lines.append("")

    for step in plan:
        op_index = step.op_index
        op = result.ops[op_index]
        lead = step.micro_op
        dr, dc = step.dst_cell
        dst_addr_val = (dr << 24) | (dc << 16)
        seq_names = " -> ".join(OPCODE_NAMES.get(o, "?") for o in step.micro_ops)

        if op.selected:
            cell = op.selected.implementation_spec.get("cell_type", "?")
            lines.extend(
                [
                    f"    // [{op_index}] {op.op_type} at cell({dr},{dc}) | {cell}",
                    f"    // micro-op sequence: {seq_names}",
                    f"    property op{op_index}_config_opcode;",
                    f"        @(posedge clk) disable iff (!rst_n)",
                    f"        (ra_valid && ra_cmd == RA_CONFIG && ra_addr == 32'h{op_index:08X}) |->",
                    f"        ra_wdata[15:8] == 8'h{lead:02X};",
                    f"    endproperty",
                    f"    assert property (op{op_index}_config_opcode)",
                    f'        else $error("[SVA FAIL] Op{op_index} {op.op_type}: config opcode mismatch (expected 0x{lead:02X})");',
                    "",
                    f"    property op{op_index}_executed;",
                    f"        @(posedge clk) disable iff (!rst_n)",
                    f"        (ra_valid && ra_cmd == RA_EXECUTE && ra_addr == 32'h{dst_addr_val:08X});",
                    f"    endproperty",
                    f"    cover property (op{op_index}_executed)",
                    f'        $display("[SVA COVER] Op{op_index} {op.op_type} executed at cell({dr},{dc})");',
                    "",
                ]
            )
        else:
            lines.extend(
                [
                    f"    // [{op_index}] {op.op_type} UNMAPPED - no SVA assertions generated",
                    "",
                ]
            )

    # Audit rule_id reference table
    op_types_seen = set()
    for step in plan:
        op_types_seen.add(str(result.ops[step.op_index].op_type).upper())

    lines.extend(
        [
            "    // ====================================================================",
            "    // Audit rule_id reference (from eda_backend.RULE_ID_MAP)",
            f"    // Op types in this design: {', '.join(sorted(op_types_seen))}",
            "    // ====================================================================",
        ]
    )

    for op_key in sorted(op_types_seen):
        if op_key in RULE_ID_MAP:
            rid = RULE_ID_MAP[op_key]
            desc, seq = get_op_sequence(op_key)
            seq_str = " -> ".join(OPCODE_NAMES.get(o, "?") for o in seq)
            lines.append(f"    // {op_key}: rule_id=0x{rid:02X} | {seq_str}")

    lines.extend(
        [
            "",
            "endmodule",
            "",
        ]
    )

    return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════
# Main entry point
# ═══════════════════════════════════════════════════════════════════


def generate_rtl_artifacts(
    result: MappingResult,
    output_dir: str = "outputs/rtlgen/",
    top_module: str = "G1_Top_Integrated",
    array_rows: int = 64,
    array_cols: int = 64,
    ir: object = None,
) -> dict:
    """
    Generate all RTL artifacts from a MappingResult.

    Args:
        result: MappingResult from eda_mapper
        output_dir: Directory to write generated files
        top_module: Name of the top-level RTL module
        array_rows: PIM array geometry (written into spl_config_pkg)
        array_cols: PIM array geometry (written into spl_config_pkg)
        ir: CausalIR instance (used by the dataflow-aware stimulus generator)

    Returns:
        dict mapping artifact name to absolute file path
    """
    os.makedirs(output_dir, exist_ok=True)

    artifacts = {}

    # 1. Config package
    pkg_path = os.path.join(output_dir, "spl_config_pkg.sv")
    with open(pkg_path, "w", encoding="utf-8") as f:
        f.write(_generate_config_pkg(result, array_rows, array_cols, ir))
    artifacts["config_pkg"] = os.path.abspath(pkg_path)

    # 2. Stimulus testbench
    stim_path = os.path.join(output_dir, "tb_eda_stimulus.sv")
    with open(stim_path, "w", encoding="utf-8") as f:
        f.write(_generate_tb_stimulus(result, array_rows, array_cols, ir))
    artifacts["tb_stimulus"] = os.path.abspath(stim_path)

    # 3. Synthesis TCL (pass output_dir as config_pkg_dir — that's where config_pkg was just written)
    tcl_path = os.path.join(
        output_dir, f"syn_{_sanitize_identifier(result.design_name)}.tcl"
    )
    with open(tcl_path, "w", encoding="utf-8") as f:
        f.write(
            _generate_syn_tcl(
                result, top_module, rtl_dir="rtl", config_pkg_dir=output_dir
            )
        )
    artifacts["syn_tcl"] = os.path.abspath(tcl_path)

    # 4. SVA assertions (formal verification)
    sva_path = os.path.join(output_dir, "causal_assertions.sv")
    with open(sva_path, "w", encoding="utf-8") as f:
        f.write(_generate_sva_assertions(result, array_rows, array_cols, ir))
    artifacts["sva_assertions"] = os.path.abspath(sva_path)

    return artifacts


def print_rtl_summary(result: MappingResult, artifacts: dict) -> None:
    """Print a summary of generated RTL artifacts."""
    total_ops = len(result.ops)
    mapped = sum(1 for o in result.ops if o.selected)
    print(f"\n[RTL生成完成] {result.design_name}")
    print(f"  算子总数: {total_ops} | 已映射: {mapped} | 未映射: {total_ops - mapped}")
    print(f"  材料: {result.material} | 策略: {result.strategy}")
    for name, path in artifacts.items():
        size = os.path.getsize(path)
        print(f"  [{name}] {path} ({size} bytes)")
