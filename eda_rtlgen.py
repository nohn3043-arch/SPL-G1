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

def _generate_config_pkg(result: MappingResult) -> str:
    """Generate spl_config_pkg.sv from mapping results."""
    lines = [
        "// ============================================================================",
        f"// spl_config_pkg — Auto-generated from EDA mapping: {result.design_name}",
        "// DO NOT EDIT MANUALLY — regenerate with: python eda_cli.py --rtl",
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
    op_types = list(set(op.op_type for op in result.ops))
    for i, ot in enumerate(op_types):
        comma = "}" if i == len(op_types) - 1 else ","
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


def _compute_config_to_rtl_op(op: OpMapping) -> str:
    """Map EDA COMPUTE op params to PIM micro-op code."""
    if op.op_type.lower() in ("compute",):
        params = getattr(op, '_orig_params', {}) or {}
        precision = params.get("precision", "INT32")
        throughput = params.get("throughput", 1)
        # Default to MUL op for COMPUTE
        return "8'h03"  # PIM MUL
    return "8'h00"  # NOP


def _generate_tb_stimulus(result: MappingResult) -> str:
    """Generate a SystemVerilog task-based stimulus file from causal IR ops."""
    lines = [
        "// ============================================================================",
        f"// tb_stimulus — Auto-generated from EDA mapping: {result.design_name}",
        "// DO NOT EDIT MANUALLY — regenerate with: python eda_cli.py --rtl",
        "// ============================================================================",
        "",
        "`timescale 1ns / 1ps",
        "",
        "// Include this file in your main testbench and call tb_stimulus_run();",
        "",
        "// ── Per-op stimulus tasks (one per causal IR op) ──",
        ""
    ]

    for op in result.ops:
        safe_name = _sanitize_identifier(f"op{op.op_index}_{op.op_type}")
        lines.extend([
            f"    // [{op.op_index}] {op.op_type}: ({', '.join(op.inputs)}) → ({', '.join(op.outputs)})",
            f"    task tb_stim_{safe_name}(",
            f"        ref logic [31:0] ra_addr,"
            f"        ref logic [63:0] ra_wdata"
            f"    );",
            f"        begin",
        ])

        if op.selected:
            cell = op.selected.implementation_spec.get("cell_type", "?")
            op_code = _compute_config_to_rtl_op(op)
            lines.extend([
                f"            // Mapped to: {cell} (delay={op.selected.delay_ns}ns)",
                f"            // RA-BUS EXECUTE to PIM array",
                f"            ra_addr  = 32'h00000000;  // PIM target, cell(0,0)",
                f"            ra_wdata = {op_code};          // micro-op",
                f"            $display(\"[STIM] [{op.op_index}] {op.op_type} → {cell}\");",
            ])
        else:
            lines.extend([
                f"            // UNMAPPED — skipping (reason: {op.failed_reason})",
                f"            $display(\"[STIM] [{op.op_index}] {op.op_type} SKIPPED (unmapped)\");",
            ])

        lines.extend([
            f"        end",
            f"    endtask",
            f"",
        ])

    # Top-level runner task
    lines.extend([
        "    // ── Top-level stimulus runner ──",
        "    task tb_stimulus_run(",
        "        ref logic [31:0] ra_addr,",
        "        ref logic [63:0] ra_wdata",
        "    );",
        "        begin",
        "            $display(\"===== Auto-generated EDA Stimulus: " + result.design_name + " =====\");",
        f"            $display(\"Material: {result.material} | Strategy: {result.strategy}\");",
        f"            $display(\"Total ops: {len(result.ops)} | Mapped: {sum(1 for o in result.ops if o.selected)}\");",
    ])

    for op in result.ops:
        safe_name = _sanitize_identifier(f"op{op.op_index}_{op.op_type}")
        lines.append(f"            tb_stim_{safe_name}(ra_addr, ra_wdata);")

    lines.extend([
        "            $display(\"===== EDA Stimulus Complete =====\");",
        "        end",
        "    endtask",
    ])
    return '\n'.join(lines)


# ═══════════════════════════════════════════════════════════════════
# Component 3: syn_tcl.tcl (Yosys-compatible synthesis script)
# ═══════════════════════════════════════════════════════════════════

def _generate_syn_tcl(result: MappingResult, top_module: str = "G1_Top_Integrated") -> str:
    """Generate a Yosys synthesis TCL script skeleton."""
    lines = [
        "# ============================================================================",
        f"# Yosys synthesis script — Auto-generated from EDA mapping: {result.design_name}",
        "# DO NOT EDIT MANUALLY — regenerate with: python eda_cli.py --rtl",
        "#",
        f"# Usage: yosys -c syn_{_sanitize_identifier(result.design_name)}.tcl",
        "# ============================================================================",
        "",
        "# ── Read design ──",
    ]

    # Collect RTL files
    rtl_files = [
        "rtl/ra_bus_arbiter.sv",
        "rtl/spl_pim_sequencer.sv",
        "rtl/spl_pim_compute_array.sv",
        "rtl/spl_pim_cell.sv",
        "rtl/spl_cim_causal_unit.sv",
        "rtl/G1_Top_Integrated.sv",
    ]

    for f in rtl_files:
        lines.append(f"read_sv {f}")

    lines.extend([
        "",
        f"# ── Hierarchy −top {top_module}",
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
    ])
    return '\n'.join(lines)


# ═══════════════════════════════════════════════════════════════════
# Main entry point
# ═══════════════════════════════════════════════════════════════════

def generate_rtl_artifacts(
    result: MappingResult,
    output_dir: str = "outputs/rtlgen/",
    top_module: str = "G1_Top_Integrated"
) -> dict:
    """
    Generate all RTL artifacts from a MappingResult.

    Args:
        result: MappingResult from eda_mapper
        output_dir: Directory to write generated files
        top_module: Name of the top-level RTL module

    Returns:
        dict mapping artifact name to absolute file path
    """
    os.makedirs(output_dir, exist_ok=True)

    artifacts = {}

    # 1. Config package
    pkg_path = os.path.join(output_dir, "spl_config_pkg.sv")
    with open(pkg_path, 'w', encoding='utf-8') as f:
        f.write(_generate_config_pkg(result))
    artifacts["config_pkg"] = os.path.abspath(pkg_path)

    # 2. Stimulus file
    stim_path = os.path.join(output_dir, "tb_stimulus.sv")
    with open(stim_path, 'w', encoding='utf-8') as f:
        f.write(_generate_tb_stimulus(result))
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
