"""
SP-EDA 工艺映射器 (v0.1.0)

遍历 CausalIR 中的每个因果算子，从 MaterialLibrary 匹配物理实现变体，
按物理约束筛选，按策略选择最优变体。

支持映射策略:
- "first_fit": 选择第一个满足所有约束的变体
- "min_delay": 在满足约束的变体中选延迟最低的
- "min_power": 在满足约束的变体中选功耗最低的
- "min_area":  在满足约束的变体中选面积最小的
"""

from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple
from enum import Enum

from EDA_fixed import (
    CausalIR, CausalOp, CausalOpType,
    PhysicalConstraints, ImplementationVariant,
    MaterialLibrary, REVERSE_OP_MAPPING,
    validate_op_params, params_affinity_score   # v0.4.0
)
# ── 芯片逻辑能力驱动的材料适配层 (v1.0.0) ──
from chip_adaptation import ChipAdapter, ChipRequirements


class MappingStrategy(Enum):
    FIRST_FIT = "first_fit"
    MIN_DELAY = "min_delay"
    MIN_POWER = "min_power"
    MIN_AREA = "min_area"


@dataclass
class OpMapping:
    """单个算子的映射结果"""
    op_index: int
    op_type: str
    inputs: List[str]
    outputs: List[str]
    selected: Optional[ImplementationVariant] = None
    alternatives: List[ImplementationVariant] = field(default_factory=list)
    all_candidates: List[ImplementationVariant] = field(default_factory=list)
    failed_reason: Optional[str] = None          # 无满足约束的变体时记录原因
    param_warnings: List[str] = field(default_factory=list)  # v0.4.0
    material: Optional[str] = None               # Stage 4: 生效的材料（per-op）


@dataclass
class MappingResult:
    """完整映射结果"""
    design_name: str
    material: str
    strategy: str
    constraints: PhysicalConstraints
    ops: List[OpMapping]
    total_delay_ns: float = 0.0
    total_power_mw: float = 0.0
    total_area_um2: float = 0.0
    min_snr_db: float = 0.0
    all_passed: bool = True
    unmapped_count: int = 0
    # ── Stage 4: 单片混装异构边界预算 ──
    # materials_used: 实际使用的材料集合
    # cross_material_edges: 跨材料数据依赖边数（需光电/接口转换）
    # material_boundary_pairs: 跨材料对统计 (src_material, dst_material) → count
    materials_used: set = field(default_factory=set)
    cross_material_edges: int = 0
    material_boundary_pairs: dict = field(default_factory=dict)
    # ── 芯片逻辑能力适配 (v1.0.0) ──
    chip_compatible: bool = True
    chip_failed: List[str] = field(default_factory=list)
    chip_notes: List[str] = field(default_factory=list)  # 计算/审计规格软检查差异

    def summary_text(self) -> str:
        # 芯片逻辑能力适配门禁：不兼容 → 直接判定失败
        if not self.chip_compatible:
            status = "FAILED (芯片逻辑能力不兼容)"
            return (
                f"映射结果 [{status}]\n"
                f"  设计: {self.design_name}\n"
                f"  材料: {self.material}\n"
                f"  芯片逻辑适配: 拒绝\n"
                f"  不兼容原因 ({len(self.chip_failed)}):\n"
                + "".join(f"    - {f}\n" for f in self.chip_failed)
            )
        status = "OK" if self.all_passed else f"FAILED ({self.unmapped_count} 个算子未映射)"
        het = ""
        if len(self.materials_used) > 1:
            pairs = ", ".join(f"{a}→{b}:{n}"
                              for (a, b), n in sorted(self.material_boundary_pairs.items()))
            het = (f"\n  单片混装: {len(self.materials_used)} 种材料 "
                   f"({' + '.join(sorted(self.materials_used))})\n"
                   f"  跨材料边界: {self.cross_material_edges} 条数据边需接口转换 [{pairs}]")
        return (
            f"映射结果 [{status}]\n"
            f"  设计: {self.design_name}\n"
            f"  材料: {self.material}\n"
            f"  策略: {self.strategy}\n"
            f"  约束: delay<={self.constraints.max_delay_ns}ns "
            f"power<={self.constraints.max_power_mw}mW "
            f"area<={self.constraints.max_area_um2}um2 "
            f"snr>={self.constraints.min_snr_db}dB\n"
            f"  合计: delay={self.total_delay_ns:.1f}ns "
            f"power={self.total_power_mw:.1f}mW "
            f"area={self.total_area_um2:.1f}um2 "
            f"min_snr={self.min_snr_db:.1f}dB\n"
            f"  算子: {len(self.ops)} 总 / {self.unmapped_count} 未映射{het}"
        )


def _variant_passes(variant: ImplementationVariant,
                    constraints: PhysicalConstraints) -> Tuple[bool, str]:
    """检查单个变体是否满足物理约束。返回 (通过, 失败原因)。"""
    if variant.delay_ns > constraints.max_delay_ns:
        return False, (
            f"delay {variant.delay_ns}ns > max {constraints.max_delay_ns}ns"
        )
    if variant.power_mw > constraints.max_power_mw:
        return False, (
            f"power {variant.power_mw}mW > max {constraints.max_power_mw}mW"
        )
    if variant.area_um2 > constraints.max_area_um2:
        return False, (
            f"area {variant.area_um2}um2 > max {constraints.max_area_um2}um2"
        )
    if variant.snr_db < constraints.min_snr_db:
        return False, (
            f"snr {variant.snr_db}dB < min {constraints.min_snr_db}dB"
        )
    return True, ""


def _select_variant(passing: List[ImplementationVariant],
                    strategy: MappingStrategy,
                    op: CausalOp = None) -> ImplementationVariant:
    """从满足约束的变体列表中按策略选择一个。
    如果只有一个变体，直接返回。
    如果有多个，用算子 params 的亲和度打分打破平局 (v0.4.0)。
    """
    if len(passing) == 1:
        return passing[0]

    # 主策略排序
    if strategy == MappingStrategy.FIRST_FIT:
        primary = passing[0]
    elif strategy == MappingStrategy.MIN_DELAY:
        primary = min(passing, key=lambda v: v.delay_ns)
    elif strategy == MappingStrategy.MIN_POWER:
        primary = min(passing, key=lambda v: v.power_mw)
    elif strategy == MappingStrategy.MIN_AREA:
        primary = min(passing, key=lambda v: v.area_um2)
    else:
        primary = passing[0]

    # 亲和度决断：如果主策略最优值和第二名差距 < 5%，用 params 重排序
    if op is not None and len(passing) > 1:
        # 找到与 primary 在关键指标上差距 < 5% 的候选
        def is_close(variant):
            if strategy == MappingStrategy.MIN_DELAY:
                return variant.delay_ns <= primary.delay_ns * 1.05
            elif strategy == MappingStrategy.MIN_POWER:
                return variant.power_mw <= primary.power_mw * 1.05
            elif strategy == MappingStrategy.MIN_AREA:
                return variant.area_um2 <= primary.area_um2 * 1.05
            return False

        close_candidates = [v for v in passing if is_close(v) or v is primary]
        if len(close_candidates) > 1:
            # 按亲和度分从高到低排序，选最高的
            close_candidates.sort(key=lambda v: params_affinity_score(op, v), reverse=True)
            return close_candidates[0]

    return primary


def map_causal_ir(
    ir: CausalIR,
    material: str,
    constraints: PhysicalConstraints,
    strategy: MappingStrategy = MappingStrategy.MIN_DELAY,
    pdk_data: Optional[Dict] = None
) -> MappingResult:
    """
    对 CausalIR 执行工艺映射。

    Args:
        ir: 因果中间表示
        material: 目标材料名称（如 "optical_mzi_photonics_v1"）
        constraints: 物理约束
        strategy: 映射策略
        pdk_data: PDK JSON 数据。若提供，则先执行「芯片逻辑能力适配」门禁，
                  材料不承载 SPL-G1 芯片逻辑能力时直接拒绝，不再做性能映射。

    Returns:
        MappingResult 包含每个算子的变体选择及汇总
    """
    # ── 芯片逻辑能力适配门禁 (v1.0.0) ──
    # 第二视角原则：适配层信息缺失 = 因果链断裂，应中断而非降级放行。
    chip_failed: List[str] = []
    chip_notes: List[str] = []
    chip_compatible = True
    if pdk_data is not None:
        try:
            adapter = ChipAdapter()
            # 修复(断裂点3)：收集所有生效材料（全局 + op.material 覆盖），
            # 对每个生效材料单独过适配门禁，任一不兼容 → 整体拒绝，
            # 防止混装设计绕过适配校验。
            op_material_set = {
                op.material for op in ir.ops if getattr(op, "material", None)
            }
            effective_materials = sorted(op_material_set | {material})
            for eff_mat in effective_materials:
                adapt_res = adapter.adapt(eff_mat, pdk_data)
                if not adapt_res.compatible:
                    chip_compatible = False
                    chip_failed.extend(
                        f"[{eff_mat}] {f}" for f in adapt_res.failed
                    )
                chip_notes.extend(
                    f"[{eff_mat}] {n}" for n in adapt_res.notes
                )
        except Exception as e:
            # 修复：适配层异常 → 明确拒绝（[中断]），不再静默放行。
            chip_compatible = False
            chip_failed = [f"芯片适配层异常(门禁未完成，拒绝映射): {e}"]

    op_mappings: List[OpMapping] = []
    total_delay = 0.0
    total_power = 0.0
    total_area = 0.0
    min_snr = float('inf')
    unmapped = 0

    # Stage 4 (单片混装): per-op material resolution.
    # op.material overrides design-wide material; None → global.
    # Tracks per-op material for the heterogeneous boundary budget.
    op_material_of = {}
    for i, op in enumerate(ir.ops):
        op_material_of[i] = op.material if getattr(op, 'material', None) else material

    for i, op in enumerate(ir.ops):
        op_code = REVERSE_OP_MAPPING.get(op.op_type, 'UNKNOWN')
        op_material = op_material_of[i]
        mapping = OpMapping(
            op_index=i,
            op_type=op_code,
            inputs=list(op.inputs),
            outputs=list(op.outputs)
        )
        mapping.material = op_material  # record effective material (Stage 4)

        # v0.4.0: 校验算子参数
        mapping.param_warnings = validate_op_params(op)

        # Stage 4: 获取该算子在该材料下的所有变体（按 op 维度，非全局）
        try:
            all_variants = MaterialLibrary.get_variants(op_material, op.op_type)
        except ValueError:
            mapping.failed_reason = f"材料 {op_material} 下无算子 {op_code} 的工艺变体"
            mapping.all_candidates = []
            unmapped += 1
            op_mappings.append(mapping)
            continue

        mapping.all_candidates = list(all_variants)

        # 按约束筛选
        passing = []
        for variant in all_variants:
            ok, reason = _variant_passes(variant, constraints)
            if ok:
                passing.append(variant)
            else:
                mapping.alternatives.append(variant)  # 保存未通过的作为备选参考

        if not passing:
            mapping.failed_reason = (
                f"共 {len(all_variants)} 个变体均不满足约束 "
                f"(delay<={constraints.max_delay_ns}, "
                f"power<={constraints.max_power_mw}, "
                f"area<={constraints.max_area_um2}, "
                f"snr>={constraints.min_snr_db})"
            )
            unmapped += 1
        else:
            selected = _select_variant(passing, strategy, op)
            mapping.selected = selected
            total_delay += selected.delay_ns
            total_power += selected.power_mw
            total_area += selected.area_um2
            min_snr = min(min_snr, selected.snr_db)

        op_mappings.append(mapping)

    # ── Stage 4: 异构边界预算（单片混装） ──
    materials_used = set(m.material for m in op_mappings if m.material)
    cross_edges = 0
    boundary_pairs: dict = {}

    # 跨材料数据边 = 消费者 op 与生产者 op 材料不同的边
    producers: dict = {}
    for i, op in enumerate(ir.ops):
        for out in op.outputs:
            producers[out] = i
    for i, op in enumerate(ir.ops):
        src_mat = op_material_of[i]
        for inp in op.inputs:
            if inp in producers:
                dst_mat = op_material_of[producers[inp]]
                if src_mat != dst_mat:
                    cross_edges += 1
                    pair = (dst_mat, src_mat)
                    boundary_pairs[pair] = boundary_pairs.get(pair, 0) + 1

    return MappingResult(
        design_name=ir.name,
        material=material,
        strategy=strategy.value,
        constraints=constraints,
        ops=op_mappings,
        total_delay_ns=total_delay,
        total_power_mw=total_power,
        total_area_um2=total_area,
        min_snr_db=min_snr if min_snr != float('inf') else 0.0,
        all_passed=(chip_compatible and unmapped == 0),
        unmapped_count=unmapped,
        materials_used=materials_used,
        cross_material_edges=cross_edges,
        material_boundary_pairs=boundary_pairs,
        chip_compatible=chip_compatible,
        chip_failed=chip_failed,
        chip_notes=chip_notes
    )
