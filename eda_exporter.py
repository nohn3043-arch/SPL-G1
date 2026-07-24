"""
SP-EDA 网表/报告输出器 (v0.1.0)

将工艺映射结果导出为结构化 JSON 网表和人类可读的文本报告。
"""

import json
import os
from typing import Optional

from eda_mapper import MappingResult, OpMapping


def _op_mapping_to_dict(op: OpMapping) -> dict:
    d = {
        "op_index": op.op_index,
        "op_type": op.op_type,
        "inputs": op.inputs,
        "outputs": op.outputs,
        "mapped": op.selected is not None,
    }
    if op.selected:
        d["selected_variant"] = {
            "cell_type": op.selected.implementation_spec.get("cell_type", "unknown"),
            "delay_ns": op.selected.delay_ns,
            "power_mw": op.selected.power_mw,
            "area_um2": op.selected.area_um2,
            "snr_db": op.selected.snr_db,
            "impl_spec": op.selected.implementation_spec,
        }
    else:
        d["failed_reason"] = op.failed_reason

    if op.alternatives:
        d["alternatives_count"] = len(op.alternatives)
        d["alternatives"] = [
            {
                "cell_type": v.implementation_spec.get("cell_type", "?"),
                "delay_ns": v.delay_ns,
                "power_mw": v.power_mw,
            }
            for v in op.alternatives
        ]

    # v0.4.0: 参数校验警告
    if op.param_warnings:
        d["param_warnings"] = op.param_warnings

    return d


def export_netlist_json(result: MappingResult, output_path: str) -> None:
    """
    将映射结果导出为 JSON 网表文件。

    Args:
        result: MappingResult 映射结果
        output_path: 输出 JSON 文件路径
    """
    netlist = {
        "design": result.design_name,
        "material": result.material,
        "strategy": result.strategy,
        "constraints": {
            "max_delay_ns": result.constraints.max_delay_ns,
            "max_power_mw": result.constraints.max_power_mw,
            "max_area_um2": result.constraints.max_area_um2,
            "min_snr_db": result.constraints.min_snr_db,
        },
        "mapping": [_op_mapping_to_dict(op) for op in result.ops],
        "summary": {
            "total_ops": len(result.ops),
            "mapped_ops": sum(1 for op in result.ops if op.selected),
            "unmapped_ops": result.unmapped_count,
            "total_delay_ns": result.total_delay_ns,
            "total_power_mw": result.total_power_mw,
            "total_area_um2": result.total_area_um2,
            "min_snr_db": result.min_snr_db,
            "all_passed": result.all_passed,
        },
    }

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(netlist, f, indent=2, ensure_ascii=False)


def generate_report(result: MappingResult) -> str:
    """
    生成人类可读的映射报告文本。

    Args:
        result: MappingResult 映射结果

    Returns:
        多行文本报告
    """
    lines = [
        "=" * 60,
        f"  SP-EDA 工艺映射报告",
        "=" * 60,
        "",
        result.summary_text(),
        "",
        "-" * 60,
        "  算子映射详情",
        "-" * 60,
    ]

    for op in result.ops:
        status = "[OK]" if op.selected else "[FAIL]"
        sel = op.selected
        lines.append(
            f"\n  [{op.op_index}] {op.op_type} {status}"
        )
        lines.append(f"      输入: ({', '.join(op.inputs)}) -> ({', '.join(op.outputs)})")

        if sel:
            cell = sel.implementation_spec.get("cell_type", "?")
            lines.append(
                f"      选中: {cell} | "
                f"delay={sel.delay_ns}ns power={sel.power_mw}mW "
                f"area={sel.area_um2}um2 snr={sel.snr_db}dB"
            )
            if len(op.all_candidates) > 1:
                others = [
                    v.implementation_spec.get("cell_type", "?")
                    for v in op.all_candidates if v != sel
                ]
                lines.append(f"      备选: {', '.join(others)}")
        else:
            lines.append(f"      失败: {op.failed_reason}")

        if op.param_warnings:
            for w in op.param_warnings:
                lines.append(f"      {w}")

    lines.extend([
        "",
        "=" * 60,
        "  报告结束",
        "=" * 60,
    ])
    return '\n'.join(lines)


def export_and_report(
    result: MappingResult,
    output_path: Optional[str] = None,
    print_report: bool = True
) -> None:
    """
    同时导出 JSON 网表和打印文本报告。

    Args:
        result: 映射结果
        output_path: JSON 输出路径（None 则不写文件）
        print_report: 是否打印报告到 stdout
    """
    if output_path:
        export_netlist_json(result, output_path)
        print(f"[网表已导出] {output_path}")

    if print_report:
        print(generate_report(result))
