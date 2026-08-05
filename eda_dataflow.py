"""
SP-EDA 数据流真实化模块 (Stage 2, v0.1.0)

目标：把因果图从"每 op 一个独立 cell、信号只出现在注释里"升级为
      "信号→cell 分配 + 读回-传递-执行 的 RA-BUS 数据流序列"。

两个核心产物：
  1. allocate_cells(ir, cols)   — 数据流感知的 cell 分配器
       - 按因果拓扑序分配 cell（生产者先于消费者）
       - 链式依赖的 op 放置到同一行相邻列 → 物理邻居互连可用
       - 每个 op 的输出信号映射到其 cell
  2. build_exec_plan(ir, alloc) — 可执行计划
       每个步骤形如 (op_index, micro_op, src_cells, dst_cell)：
       - src_cells: 该 op 消费的前驱输出 cell（需先 RA-BUS READ 读回）
       - dst_cell:  该 op 的结果存储 cell

注意：micro-op 语义编码见 eda_rtlgen.CAUSAL_OP_TO_MICRO（占位，
      待 Phase A5 NOMOS 约束规则精确定义）。
"""

from typing import Dict, List, Tuple, Optional
from collections import deque

# ── 微码编码（与 eda_rtlgen.CAUSAL_OP_TO_MICRO 保持一致） ──
CAUSAL_OP_TO_MICRO = {
    "NS":      0x01,   # ADD     (placeholder)
    "IAP":     0x08,   # CMP_EQ  (placeholder)
    "LCH":     0x0B,   # CMP_GT  (placeholder)
    "CCS":     0x00,   # NOP     (placeholder)
    "STATE":   0x1B,   # STORE   (placeholder)
    "COMPUTE": 0x05,   # MUL     (placeholder)
}

# RA-BUS cell addressing (from spl_pim_compute_array.sv)
#   cell(r,c) → ra_addr = (r<<24)|(c<<16), target bits[29:28]=00


def _cell_addr(r: int, c: int) -> int:
    return (r << 24) | (c << 16)


def _op_code(op_type) -> int:
    """Map a CausalOpType (or string code) to a PIM micro-op."""
    if hasattr(op_type, "value"):
        # CausalOpType enum → uppercase code, e.g. NARRATIVE_STRIP → NS
        name = op_type.name.upper()
        if name == "NARRATIVE_STRIP":
            return CAUSAL_OP_TO_MICRO["NS"]
        if name == "ASSUMPTION_DETECT":
            return CAUSAL_OP_TO_MICRO["IAP"]
        if name == "VULNERABILITY_HEDGE":
            return CAUSAL_OP_TO_MICRO["LCH"]
        if name == "CAUSAL_CLOCK_SYNC":
            return CAUSAL_OP_TO_MICRO["CCS"]
        if name == "STATE_UPDATE":
            return CAUSAL_OP_TO_MICRO["STATE"]
        if name == "COMPUTE":
            return CAUSAL_OP_TO_MICRO["COMPUTE"]
        return 0x00
    return CAUSAL_OP_TO_MICRO.get(str(op_type).upper(), 0x00)


class CellAllocation:
    """信号→cell 映射 + op→cell 映射 + 拓扑序。"""
    def __init__(self):
        self.signal_cell: Dict[str, Tuple[int, int]] = {}
        self.op_cell: Dict[int, Tuple[int, int]] = {}
        self.topological: List[int] = []   # op_index 拓扑序


def allocate_cells(ir, array_cols: int = 64) -> CellAllocation:
    """
    数据流感知的 cell 分配器。

    策略：
      - 使用 ir.dataflow（信号→消费者）与生产关系做拓扑排序（Kahn）。
      - 按拓扑序逐 op 分配 cell，行优先，链式依赖的 op 天然落相邻列。
      - op 的每个输出信号映射到该 op 的 cell；顶层输入不占 cell
        （值由 RA-BUS 外部提供）。

    约束：
      - 数组大小必须 ≥ op 数量（否则无法完成分配）。
    """
    alloc = CellAllocation()
    n_ops = len(ir.ops)

    if n_ops > array_cols * 64:
        raise ValueError(
            f"数据流分配失败：{n_ops} 个算子超过 64×{array_cols} cell 容量"
        )

    # ── 生产关系：信号 → 生产者 op_index ──
    producer: Dict[str, int] = {}
    for i, op in enumerate(ir.ops):
        for out in op.outputs:
            producer[out] = i

    # ── Kahn 拓扑排序（按 ir.ops 顺序作为稳定性参考） ──
    in_degree = [0] * n_ops
    consumers: Dict[int, List[int]] = {i: [] for i in range(n_ops)}
    for i, op in enumerate(ir.ops):
        for inp in op.inputs:
            if inp in producer:
                p = producer[inp]
                in_degree[i] += 1
                consumers[p].append(i)

    queue = deque([i for i in range(n_ops) if in_degree[i] == 0])
    topo: List[int] = []
    while queue:
        i = queue.popleft()
        topo.append(i)
        for j in sorted(consumers[i]):
            in_degree[j] -= 1
            if in_degree[j] == 0:
                queue.append(j)
    if len(topo) != n_ops:
        raise ValueError("数据流分配失败：因果图存在循环依赖（应先通过 CausalIR.validate）")

    alloc.topological = topo

    # ── 按拓扑序分配 cell（行优先） ──
    for idx, op_index in enumerate(topo):
        r = idx // array_cols
        c = idx % array_cols
        alloc.op_cell[op_index] = (r, c)
        op = ir.ops[op_index]
        for out in op.outputs:
            alloc.signal_cell[out] = (r, c)

    return alloc


def _src_of_op(ir, op_index: int, alloc: CellAllocation) -> List[Tuple[str, int, int]]:
    """返回该 op 消费的前驱信号及其源 cell 列表（按输入顺序）。"""
    srcs = []
    op = ir.ops[op_index]
    for inp in op.inputs:
        if inp in alloc.signal_cell:
            srcs.append((inp,) + alloc.signal_cell[inp])
    return srcs


class ExecStep:
    """单个执行步骤：读回源 cell → 对目标 cell 执行 micro-op。"""
    def __init__(self, op_index: int, op_type: str,
                 src_cells: List[Tuple[str, int, int]],
                 dst_cell: Tuple[int, int],
                 micro_op: int, cell_name: str):
        self.op_index = op_index
        self.op_type = op_type
        self.src_cells = src_cells            # (signal_name, row, col)
        self.dst_cell = dst_cell              # (row, col)
        self.micro_op = micro_op
        self.cell_name = cell_name


def build_exec_plan(ir, alloc: CellAllocation,
                    cell_names: Optional[Dict[int, str]] = None) -> List[ExecStep]:
    """
    生成可执行计划。每个 op 一个步骤：
      - src_cells: 需先读回的前驱 cell（数据依赖）
      - dst_cell:  结果存储 cell
    """
    plan: List[ExecStep] = []
    for op_index in alloc.topological:
        op = ir.ops[op_index]
        micro = _op_code(op.op_type)
        srcs = _src_of_op(ir, op_index, alloc)
        dst = alloc.op_cell[op_index]
        name = ""
        if cell_names and op_index in cell_names:
            name = cell_names[op_index]
        plan.append(ExecStep(
            op_index=op_index,
            op_type=op.op_type,
            src_cells=srcs,
            dst_cell=dst,
            micro_op=micro,
            cell_name=name,
        ))
    return plan
