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
    OP_SEQUENCES, RULE_ID_MAP, CausalRecord,
    build_causal_record, build_design_provenance,
    get_op_sequence, opcode_list_to_names, opcode_list_to_hex,
)

CAUSAL_OP_TO_MICRO = {
    "NS":      OP_SEQUENCES["NS"]["seq"][0][0],
    "IAP":     OP_SEQUENCES["IAP"]["seq"][0][0],
    "LCH":     OP_SEQUENCES["LCH"]["seq"][0][0],
    "CCS":     OP_SEQUENCES["CCS"]["seq"][0][0],
    "STATE":   OP_SEQUENCES["STATE"]["seq"][0][0],
    "COMPUTE": OP_SEQUENCES["COMPUTE"]["seq"][0][0],
}

# ── RA-BUS cell addressing (from spl_pim_compute_array.sv) ──
#   cell(r,c) → ra_addr = (r << 24) | (c << 16),  target bits[29:28]=00
#   sequencer program entry → ra_addr[9:0]


def _generate_config_pkg(result: MappingResult,
                         array_rows: int = 64,
                         array_cols: int = 64,
                         ir: object = None) -> str:
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
        ""
    ]

    # Design metadata
    lines.extend([
        f"    // ── Design: {result.design_name} ──",
        f"    localparam string DESIGN_NAME = \"{result.design_name}\";",
        f"    localparam string MATERIAL    = \"{result.material}\";",
        f"    localparam string STRATEGY    = \"{result.strategy}\";",
        "",
        "    // ── Array geometry (EDA-driven; G1_Top reads these) ──",
        f"    localparam int    PIM_ROWS    = {array_rows};",
        f"    localparam int    PIM_COLS    = {array_cols};",
        ""
    ])

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
            safe_cell = re.sub(r'[^A-Za-z0-9_]', '_', cell).upper()
            lines.extend([
                f"    //  [{op.op_index}] {op.op_type} → {cell}",
                f"    localparam string {safe}_CELL     = \"{cell}\";",
                f"    localparam real   {safe}_DELAY_NS = {sel.delay_ns};",
                f"    localparam real   {safe}_POWER_MW = {sel.power_mw};",
                f"    localparam real   {safe}_AREA_UM2 = {sel.area_um2};",
                f"    localparam real   {safe}_SNR_DB   = {sel.snr_db};",
            ])
            # Export implementation_spec as individual params
            for k, v in sel.implementation_spec.items():
                if isinstance(v, (int, float)):
                    safe_k = re.sub(r'[^A-Za-z0-9_]', '_', str(k)).upper()
                    lines.append(f"    localparam real   {safe}_{safe_k} = {v};")
        else:
            lines.extend([
                f"    //  [{op.op_index}] {op.op_type} — UNMAPPED: {op.failed_reason}",
            ])
        lines.append("")

    # ════════════════════════════════════════════════════════════
    # Backend semantics block (v0.2.0) — micro-op sequences + audit records
    # ════════════════════════════════════════════════════════════
    # Derived from eda_backend.py; per-op microcode sequences match the
    # real spl_pim_cell.v2 opcode table, and each causal record matches
    # the spl_cim_causal_unit.v2 wr_data_p/wr_data_q wire format.
    lines.append("    // ════════════════════════════════════════════════════════════")
    lines.append("    // ── Backend semantics (v0.2.0): micro-op sequences + audit records ──")
    lines.append("    // ════════════════════════════════════════════════════════════")

    # Producer map: signal → op_index (for dependency mask construction)
    producer_of: dict = {}
    if ir is not None and hasattr(ir, 'ops'):
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
        lines.extend([
            f"    //  [{op.op_index}] {op_key} backend sequence ({seq_desc})",
            f"    localparam logic [4:0] {safe}_MICRO_OP   = 5'h{lead:02X};  // lead opcode",
            f"    localparam string {safe}_MICRO_SEQ  = \"{seq_names}\";",
            f"    localparam string {safe}_MICRO_HEX  = \"{seq_hex}\";",
        ])
        # 2) audit record (Causal Record → spl_cim_causal_unit v2)
        #    producer indices from the IR dataflow
        prod_idx: List[int] = []
        if ir is not None and hasattr(ir, 'ops'):
            op_i = op.op_index
            if 0 <= op_i < len(ir.ops):
                for _inp in ir.ops[op_i].inputs:
                    if _inp in producer_of:
                        prod_idx.append(producer_of[_inp])
        rec = build_causal_record(
            op_key, op.op_index, prod_idx,
            design_hash=design_hash,
        )
        rec_p = rec.pack_p()
        rec_q = rec.pack_q()
        lines.extend([
            f"    //  audit record: rule={rec.rule_id:#04x} dep_mask={rec.dep_mask:014x} "
            f"weight_q16_16={rec.weight_q16_16:#x}",
            f"    localparam logic [255:0] {safe}_AUDIT_P = 256'h{rec_p:064x};",
            f"    localparam logic [255:0] {safe}_AUDIT_Q = 256'h{rec_q:064x};",
        ])
        lines.append("")

    lines.extend([
        "endpackage",
        ""
    ])
    return '\n'.join(lines)


# ═══════════════════════════════════════════════════════════════════
# Component 2: tb_stimulus.sv
# ═══════════════════════════════════════════════════════════════════

def _sanitize_identifier(s: str) -> str:
    """Sanitize a string into a valid Verilog identifier."""
    return re.sub(r'[^A-Za-z0-9_]', '_', s)


def _generate_tb_stimulus(result: MappingResult,
                          array_rows: int = 64,
                          array_cols: int = 64,
                          ir: object = None) -> str:
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
        f"        $display(\"===== EDA Stimulus: {result.design_name} =====\");",
        f"        $display(\"Material: {result.material} | Strategy: {result.strategy}\");",
        f"        $display(\"Total ops: {len(result.ops)} | Mapped: {sum(1 for o in result.ops if o.selected)}\");",
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
            ops=[CausalOp(op_type=op.op_type,
                          inputs=op.inputs, outputs=op.outputs)
                 for op in result.ops],
        )
    else:
        ir_obj = ir

    from eda_dataflow import allocate_cells, build_exec_plan

    alloc = allocate_cells(ir_obj, array_cols)
    cell_names = {i: (op.selected.implementation_spec.get("cell_type", "?")
                      if op.selected else "UNMAPPED")
                  for i, op in enumerate(result.ops)}
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
        src_desc = ", ".join(f"cell({r},{c})←{name}"
                             for name, r, c in step.src_cells) or "none (external)"
        if op.selected:
            cell = op.selected.implementation_spec.get("cell_type", "?")
            lines.extend([
                f"        // ── [{op_index}] {op.op_type}: ({', '.join(op.inputs)}) → ({', '.join(op.outputs)}) ──",
                f"        // mapped to {cell} (delay={op.selected.delay_ns}ns, power={op.selected.power_mw}mW)",
                f"        // micro-op 0x{micro:02X} @ cell({dr},{dc}) | sources: {src_desc}",
                f"        ra_config(32'h{op_index:08X}, {{40'h0, 8'd1, 8'h{micro:02X}, 6'h0, 2'b01}});",
            ])
            # Real dataflow: read back every predecessor cell via RA-BUS READ
            if step.src_cells:
                for name, sr, sc in step.src_cells:
                    if name in sig_index:
                        lines.append(
                            f"        ra_read(32'h{sr:02X}{sc:02X}0000);  // read back {name}"
                        )
                        lines.append(
                            f"        sig_val[{sig_index[name]}] = ra_rdata;"
                        )
                sname, sr, sc = step.src_cells[0]
                if sname in sig_index:
                    lines.append(
                        f"        ra_execute({dst_addr}, sig_val[{sig_index[sname]}]);  // pass {sname} → {op.op_type}"
                    )
            else:
                lines.append(f"        ra_execute({dst_addr}, 64'd{op_index});  // external input")
            lines.append(f"        repeat(4) @(posedge clk);")
            lines.append("")
        else:
            lines.extend([
                f"        // [{op_index}] {op.op_type} UNMAPPED — skipped (reason: {op.failed_reason})",
                "",
            ])

    # Inject the actual signal count into the sig_val declaration
    lines_str = '\n'.join(lines)
    lines_str = lines_str.replace("__SIG_NUM__", str(sig_num))
    lines = lines_str.split('\n')

    lines.extend([
        "        // ── Audit pipeline settles ──",
        "        repeat(40) @(posedge clk);",
        "",
        "        if (fuse_blown === 1'b0 && pim_state_stable === 1'b1)",
        "            $display(\"[PASS] EDA stimulus completed: array stable, fuse intact\");",
        "        else begin",
        "            $display(\"[FAIL] fuse_blown=%b pim_state_stable=%b\", fuse_blown, pim_state_stable);",
        "            errors = errors + 1;",
        "        end",
        "",
        "        $display(\"===== Results: %0d errors =====\", errors);",
        "        $finish;",
        "    end",
        "",
        "endmodule",
    ])
    return '\n'.join(lines)


# ═══════════════════════════════════════════════════════════════════
# Component 3: syn_tcl.tcl (Yosys-compatible synthesis script)
# ═══════════════════════════════════════════════════════════════════

def _generate_syn_tcl(result: MappingResult,
                      top_module: str = "G1_Top_Integrated",
                      rtl_dir: str = "rtl") -> str:
    """Generate a Yosys synthesis script skeleton.

    Stage 1 (缝3 打通): RTL files are discovered dynamically via Tcl glob
    instead of a hardcoded 6-file list (which previously dropped
    ext_mem_controller and materica_compliance_unit). The generated
    spl_config_pkg.sv is read FIRST so G1_Top's import resolves.
    """
    lines = [
        "# ============================================================================",
        f"# Yosys synthesis script — Auto-generated from EDA mapping: {result.design_name}",
        "# DO NOT EDIT MANUALLY — regenerate with: python eda_cli.py --rtl",
        "#",
        f"# Usage: yosys -c syn_{_sanitize_identifier(result.design_name)}.tcl",
        "# ============================================================================",
        "",
        "# ── Read design (dynamic discovery; EDA-generated config first) ──",
        f"read_sv {rtl_dir}/spl_config_pkg.sv",
        "",
        "set rtl_files [glob -nocomplain {rtl}/*.sv]",
        "set rtl_files [lsearch -all -inline -not -exact $rtl_files {rtl}/spl_config_pkg.sv]",
        "set rtl_files [lsearch -all -inline -not -exact $rtl_files {rtl}/tb_eda_stimulus.sv]",
        "set rtl_files [lsearch -all -inline -not -exact $rtl_files {rtl}/tb_G1_Integrated.sv]",
        "foreach f $rtl_files {",
        "    read_sv $f",
        "}",
        "",
        f"# ── Hierarchy -top {top_module}",
        f"hierarchy -top {top_module}",
        "",
        "# ── Process",
        "proc",
        "opt",
        "",
        "# ── Technology mapping (generic)",
        "techmap",
        "opt",
        "",
        "# ── Report",
        f"stat -top {top_module}",
        "select -count t:*",
        "",
        "# ── Write netlist",
        f"write_json outputs/{result.design_name}_syn.json",
        f"write_verilog outputs/{result.design_name}_syn.v",
        "",
        "# ── Timing (no SDC loaded; add .sdc file when available)",
        "# read_sdc constraints/g1_timing.sdc",
    ]
    return '\n'.join(lines)


# ═══════════════════════════════════════════════════════════════════
# Main entry point
# ═══════════════════════════════════════════════════════════════════

def generate_rtl_artifacts(
    result: MappingResult,
    output_dir: str = "outputs/rtlgen/",
    top_module: str = "G1_Top_Integrated",
    array_rows: int = 64,
    array_cols: int = 64,
    ir: object = None
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
    with open(pkg_path, 'w', encoding='utf-8') as f:
        f.write(_generate_config_pkg(result, array_rows, array_cols, ir))
    artifacts["config_pkg"] = os.path.abspath(pkg_path)

    # 2. Stimulus testbench
    stim_path = os.path.join(output_dir, "tb_eda_stimulus.sv")
    with open(stim_path, 'w', encoding='utf-8') as f:
        f.write(_generate_tb_stimulus(result, array_rows, array_cols, ir))
    artifacts["tb_stimulus"] = os.path.abspath(stim_path)

    # 3. Synthesis TCL
    tcl_path = os.path.join(output_dir, f"syn_{_sanitize_identifier(result.design_name)}.tcl")
    with open(tcl_path, 'w', encoding='utf-8') as f:
        f.write(_generate_syn_tcl(result, top_module))
    artifacts["syn_tcl"] = os.path.abspath(tcl_path)

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
