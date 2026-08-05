"""
SP-EDA 因果描述解析器 (v0.1.0)

读取 JSON 格式的行为级因果描述，构造 CausalIR 中间表示并执行拓扑校验。

输入 JSON 格式:
{
  "design_name": "my_design",
  "inputs": ["signal_a", "signal_b"],
  "outputs": ["decision"],
  "operators": [
    {
      "op_type": "NS",
      "inputs": ["signal_a"],
      "outputs": ["stripped_a"],
      "params": {}
    },
    ...
  ]
}
"""

import json
from typing import List, Dict, Any

from EDA_fixed import (
    CausalOp, CausalIR, CausalOpType,
    OP_MAPPING, REVERSE_OP_MAPPING
)


class ParserError(Exception):
    """解析阶段异常"""
    pass


def parse_causal_description(file_path: str) -> CausalIR:
    """
    从 JSON 文件解析因果描述，构建并校验 CausalIR。

    Args:
        file_path: 因果描述 JSON 文件路径

    Returns:
        校验通过的 CausalIR 实例

    Raises:
        ParserError: JSON 格式不合法、算子类型无效、数据流有缺陷
    """
    with open(file_path, 'r', encoding='utf-8') as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            raise ParserError(f"JSON 语法错误: {e}")

    # 1. 校验顶层字段
    design_name = data.get('design_name', 'unnamed')
    inputs = data.get('inputs')
    outputs = data.get('outputs')
    operators_raw = data.get('operators')

    if not isinstance(inputs, list) or len(inputs) == 0:
        raise ParserError("缺失或为空的 inputs 字段")
    if not isinstance(outputs, list) or len(outputs) == 0:
        raise ParserError("缺失或为空的 outputs 字段")
    if not isinstance(operators_raw, list) or len(operators_raw) == 0:
        raise ParserError("缺失或为空的 operators 字段")

    # 2. 构建 CausalOp 列表
    ops: List[CausalOp] = []
    for i, op_spec in enumerate(operators_raw):
        op_type_str = op_spec.get('op_type', '').upper()
        if op_type_str not in OP_MAPPING:
            valid = ', '.join(sorted(OP_MAPPING.keys()))
            raise ParserError(
                f"算子 #{i}: 无效类型 '{op_spec.get('op_type')}'，"
                f"合法值为: {valid}"
            )

        op_inputs = op_spec.get('inputs', [])
        op_outputs = op_spec.get('outputs', [])
        if not isinstance(op_inputs, list) or len(op_inputs) == 0:
            raise ParserError(f"算子 #{i} ({op_type_str}): 缺失或为空的 inputs")
        if not isinstance(op_outputs, list) or len(op_outputs) == 0:
            raise ParserError(f"算子 #{i} ({op_type_str}): 缺失或为空的 outputs")

        # Stage 4: per-op material override (单片混装).
        # Optional "material" key per operator; None → design-wide material.
        op_material = op_spec.get('material')
        if op_material is not None and not isinstance(op_material, str):
            raise ParserError(
                f"算子 #{i} ({op_type_str}): material 字段必须为字符串或省略"
            )

        op = CausalOp(
            op_type=OP_MAPPING[op_type_str],
            inputs=op_inputs,
            outputs=op_outputs,
            params=op_spec.get('params', {}),
            material=op_material
        )
        ops.append(op)

    # 3. 构建 CausalIR（build_dataflow + validate 在 __post_init__ 中自动执行）
    try:
        ir = CausalIR(
            name=design_name,
            inputs=inputs,
            outputs=outputs,
            ops=ops
        )
    except ValueError as e:
        raise ParserError(f"CausalIR 构建失败: {e}")

    return ir


def describe_ir(ir: CausalIR) -> str:
    """生成 CausalIR 的可读摘要，用于调试和报告。"""
    lines = [
        f"设计名称: {ir.name}",
        f"输入信号: {', '.join(ir.inputs)}",
        f"输出信号: {', '.join(ir.outputs)}",
        f"算子数量: {len(ir.ops)}",
        f"",
        f"算子清单:",
    ]
    for i, op in enumerate(ir.ops):
        op_code = REVERSE_OP_MAPPING.get(op.op_type, 'UNKNOWN')
        lines.append(
            f"  [{i}] {op_code}: "
            f"({', '.join(op.inputs)}) -> ({', '.join(op.outputs)})"
        )
    return '\n'.join(lines)
