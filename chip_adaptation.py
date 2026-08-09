"""
SPL-G1 芯片逻辑能力驱动的材料适配层 (v1.0.0)

背景:
  原有 eda_mapper.py 仅按通用物理指标 (delay/power/area/snr) 筛选材料变体，
  与芯片 RTL 逻辑能力脱节。本模块以 rtl/*.sv 实际实现的逻辑能力为基准，
  对候选材料执行「芯片逻辑能力适配」硬门禁（Materica 4 条 + 计算/审计/IO 规格）。

与 eda_mapper 的关系:
  - 本模块是映射的「前置合规层」：先验材料是否承载 SPL-G1 芯片逻辑，
    再交 eda_mapper 做性能寻优。
  - 不满足适配门禁的材料，即使 delay/power/area/snr 再优，也拒绝映射。

芯片能力基准来源 (chip_requirements.json):
  M1 逻辑状态稳定性 (spl_pim_cell.sv)
  M2 因果定向路由   (ra_bus_arbiter.sv + spl_pim_compute_array.sv)
  M3 存算一体近接性 (spl_pim_cell.sv PIM + EVOLVE)
  M4 安全边界不可逆 (G1_Top_Integrated.sv fuse_blown)
  + 计算/审计/IO 规格
"""

import json
import os
from dataclasses import dataclass, field
from typing import Dict, List, Any, Optional


# ─────────────────────────────────────────────────────────────
# 1. 芯片能力需求模型
# ─────────────────────────────────────────────────────────────

@dataclass
class ChipRequirements:
    """芯片逻辑能力需求基准（从 chip_requirements.json 加载）"""
    chip: str
    version: str
    materica: Dict[str, Any]
    compute: Dict[str, Any]
    audit: Dict[str, Any]
    io: Dict[str, Any]

    @classmethod
    def load(cls, path: Optional[str] = None) -> "ChipRequirements":
        path = path or os.path.join(os.path.dirname(__file__), "chip_requirements.json")
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return cls(
            chip=data.get("chip", "SPL-G1"),
            version=data.get("version", ""),
            materica=data.get("materica_constraints", {}),
            compute=data.get("compute_requirements", {}),
            audit=data.get("audit_requirements", {}),
            io=data.get("io_requirements", {}),
        )


# ─────────────────────────────────────────────────────────────
# 2. 材料物理能力模型（从 PDK JSON 的 materica 字段解析）
# ─────────────────────────────────────────────────────────────

@dataclass
class MaterialCapability:
    """材料的物理能力声明。对应 Materica 4 条 + 计算规格。"""
    # M1
    stable_states: int = 0
    activation_energy_over_noise: float = 0.0
    # M2
    directional_signal: bool = False
    isotropic_diffusion: bool = True          # True = 各向同性扩散（应禁止）
    # M3
    pim_co_location: bool = False
    transport_energy_uj: float = float("inf")
    # M4
    irreversible_boundary: bool = False
    # compute spec
    data_width_bits: int = 0
    neighbour_bits: int = 0
    alu_op_count: int = 0
    precision_supported: List[str] = field(default_factory=list)
    execution_modes: List[str] = field(default_factory=list)
    # audit spec
    causal_record_bits: int = 0
    constraint_mask_bits: int = 0
    dependency_mask_bits: int = 0
    cascade_invalidation: bool = False
    # 可选扩展字段
    extra: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_pdk(cls, pdk: Dict[str, Any]) -> "MaterialCapability":
        """从 PDK JSON 顶层 materica 字段解析材料能力（缺失字段用默认值 → 视为不满足）。"""
        m = pdk.get("materica", {})

        # M1
        m1 = m.get("M1_logic_state_stability", {})
        # M2
        m2 = m.get("M2_causal_directional_routing", {})
        # M3
        m3 = m.get("M3_pim_proximity", {})
        # M4
        m4 = m.get("M4_security_boundary_irreversibility", {})

        comp = pdk.get("compute", {})

        return cls(
            stable_states=int(m1.get("stable_states", 0)),
            activation_energy_over_noise=float(m1.get("activation_energy_over_noise", 0.0)),
            directional_signal=bool(m2.get("directional_signal", False)),
            isotropic_diffusion=bool(m2.get("isotropic_diffusion", True)),
            pim_co_location=bool(m3.get("pim_co_location", False)),
            transport_energy_uj=float(m3.get("transport_energy_uj", float("inf"))),
            irreversible_boundary=bool(m4.get("irreversible_boundary", False)),
            data_width_bits=int(comp.get("data_width_bits", 0)),
            neighbour_bits=int(comp.get("neighbour_interconnect_bits", 0)),
            alu_op_count=int(comp.get("alu_op_count", 0)),
            precision_supported=list(comp.get("precision_supported", [])),
            execution_modes=list(comp.get("execution_modes", [])),
            causal_record_bits=int(pdk.get("audit", {}).get("causal_record_bits", 0)),
            constraint_mask_bits=int(pdk.get("audit", {}).get("constraint_mask_bits", 0)),
            dependency_mask_bits=int(pdk.get("audit", {}).get("dependency_mask_bits", 0)),
            cascade_invalidation=bool(pdk.get("audit", {}).get("cascade_invalidation", False)),
            extra=pdk.get("extra", {}),
        )


# ─────────────────────────────────────────────────────────────
# 3. 适配结果 & 校验器
# ─────────────────────────────────────────────────────────────

@dataclass
class AdaptationResult:
    """芯片逻辑能力适配结果"""
    material: str
    compatible: bool
    passed: List[str] = field(default_factory=list)
    failed: List[str] = field(default_factory=list)
    notes: List[str] = field(default_factory=list)  # 计算/审计规格软检查差异

    def to_dict(self) -> Dict[str, Any]:
        return {
            "material": self.material,
            "compatible": self.compatible,
            "passed": self.passed,
            "failed": self.failed,
            "notes": self.notes,
        }


class ChipAdapter:
    """以芯片 RTL 逻辑能力为基准的材料适配校验器"""

    def __init__(self, requirements: Optional[ChipRequirements] = None):
        self.req = requirements or ChipRequirements.load()

    def _check_materica(self, cap: MaterialCapability) -> List[str]:
        """Materica 4 条硬门禁。返回不满足项列表（空 = 全过）。"""
        fails = []
        mc = self.req.materica

        m1 = mc.get("M1_logic_state_stability", {})
        if cap.stable_states < int(m1.get("required_states", 2)):
            fails.append(
                f"M1 逻辑状态稳定性: 需 ≥{m1.get('required_states')} 种稳定态, 实际 {cap.stable_states}"
            )
        if cap.activation_energy_over_noise < float(m1.get("activation_energy_over_noise_min", 10.0)):
            fails.append(
                f"M1 激活能/热噪声: 需 ≥{m1.get('activation_energy_over_noise_min')}x, "
                f"实际 {cap.activation_energy_over_noise}x"
            )

        m2 = mc.get("M2_causal_directional_routing", {})
        if m2.get("directional_signal_required", True) and not cap.directional_signal:
            fails.append("M2 因果定向路由: 材料必须支持定向信号 (directional_signal=true)")
        if m2.get("isotropic_diffusion_forbidden", True) and cap.isotropic_diffusion:
            fails.append("M2 因果定向路由: 禁止各向同性扩散 (isotropic_diffusion 必须为 false)")

        m3 = mc.get("M3_pim_proximity", {})
        if m3.get("pim_co_location_required", True) and not cap.pim_co_location:
            fails.append("M3 存算一体近接性: 材料必须支持逻辑/存储共位 (pim_co_location=true)")
        if cap.transport_energy_uj > float(m3.get("transport_energy_target_uj", 0.0)):
            fails.append(
                f"M3 存算一体近接性: 数据搬运能耗需趋近 {m3.get('transport_energy_target_uj')}uJ, "
                f"实际 {cap.transport_energy_uj}uJ"
            )

        m4 = mc.get("M4_security_boundary_irreversibility", {})
        if m4.get("irreversible_boundary_required", True) and not cap.irreversible_boundary:
            fails.append("M4 安全边界不可逆性: 材料必须提供物理不可逆隔离 (irreversible_boundary=true)")

        return fails

    def _check_compute(self, cap: MaterialCapability) -> List[str]:
        """计算规格软检查。仅报告与参考规格（硅基档位）的差异，不否决兼容性。"""
        notes = []
        comp = self.req.compute
        if cap.data_width_bits < int(comp.get("data_width_bits", 128)):
            notes.append(
                f"计算-数据位宽: 材料 {cap.data_width_bits}bit, 参考规格 {comp.get('data_width_bits')}bit (材料自定，允许)"
            )
        if cap.neighbour_bits < int(comp.get("neighbour_interconnect_bits", 8)):
            notes.append(
                f"计算-邻居互连: 材料 {cap.neighbour_bits}bit, 参考规格 {comp.get('neighbour_interconnect_bits')}bit (材料自定，允许)"
            )
        if cap.alu_op_count < int(comp.get("alu_op_count", 32)):
            notes.append(f"计算-ALU 操作: 材料 {cap.alu_op_count}, 参考规格 {comp.get('alu_op_count')} (材料自定，允许)")
        # 精度：报告材料支持的精度集
        notes.append(f"计算-精度: 材料支持 {sorted(cap.precision_supported) or '未声明'}")
        # 执行模式
        notes.append(f"计算-执行模式: 材料支持 {sorted(cap.execution_modes) or '未声明'}")
        return notes

    def _check_audit(self, cap: MaterialCapability) -> List[str]:
        """审计规格软检查。仅报告与参考规格（硅基档位）的差异，不否决兼容性。"""
        notes = []
        audit = self.req.audit
        if cap.causal_record_bits < int(audit.get("causal_record_bits", 256)):
            notes.append(f"审计-因果记录位宽: 材料 {cap.causal_record_bits}bit, 参考规格 {audit.get('causal_record_bits')}bit (材料自定，允许)")
        if cap.constraint_mask_bits < int(audit.get("constraint_mask_bits", 64)):
            notes.append(f"审计-约束掩码: 材料 {cap.constraint_mask_bits}bit, 参考规格 {audit.get('constraint_mask_bits')}bit (材料自定，允许)")
        if cap.dependency_mask_bits < int(audit.get("dependency_mask_bits", 56)):
            notes.append(f"审计-依赖掩码: 材料 {cap.dependency_mask_bits}bit, 参考规格 {audit.get('dependency_mask_bits')}bit (材料自定，允许)")
        if not cap.cascade_invalidation:
            notes.append("审计-级联失效: 材料未声明级联失效 (允许，按材料能力)")
        return notes

    def adapt(self, material: str, pdk: Dict[str, Any]) -> AdaptationResult:
        """对单个材料的 PDK 做芯片逻辑能力适配。

        材料无关适配策略:
          - 跨材料硬门禁 = Materica M1-M4（逻辑/安全前提，所有承载 SPL-G1 逻辑的材料必须满足）
          - 计算/审计规格 = 软检查（材料自定档位，仅记录差异，不否决）
        """
        cap = MaterialCapability.from_pdk(pdk)
        # 硬门禁：仅 M1-M4
        fails = self._check_materica(cap)
        # 软检查：计算/审计规格（记录差异，不否决）
        notes = []
        notes += self._check_compute(cap)
        notes += self._check_audit(cap)

        if fails:
            return AdaptationResult(
                material=material, compatible=False, failed=fails,
                passed=[], notes=notes,
            )
        return AdaptationResult(
            material=material, compatible=True,
            passed=[
                "M1 逻辑状态稳定性",
                "M2 因果定向路由",
                "M3 存算一体近接性",
                "M4 安全边界不可逆性",
            ],
            notes=notes,
        )


def adapt_pdk_from_path(material: str, pdk_path: str, adapter: Optional[ChipAdapter] = None) -> AdaptationResult:
    """便捷入口：从 PDK 文件路径执行芯片逻辑能力适配。"""
    adapter = adapter or ChipAdapter()
    with open(pdk_path, "r", encoding="utf-8") as f:
        pdk = json.load(f)
    return adapter.adapt(material, pdk)


if __name__ == "__main__":
    import sys
    req = ChipRequirements.load()
    adapter = ChipAdapter(req)
    print(f"芯片能力基准: {req.chip} v{req.version}")
    print(f"Materica 约束: {list(req.materica.keys())}\n")
    for p in sorted(os.listdir("pdk")):
        if p.endswith(".json"):
            mat = p.replace(".json", "")
            r = adapt_pdk_from_path(mat, os.path.join("pdk", p), adapter)
            status = "COMPATIBLE" if r.compatible else "INCOMPATIBLE"
            print(f"  [{status}] {mat}")
            for f in r.failed:
                print(f"        └─ {f}")
            if r.notes:
                print(f"        └─ 材料自定规格(软检查):")
                for n in r.notes:
                    print(f"              · {n}")
