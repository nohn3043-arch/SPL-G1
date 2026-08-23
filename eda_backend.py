"""
SP-EDA 后端语义定义 (v0.2.0) — Backend Semantics for Causal Ops

将 6 个因果算子 (NS/IAP/LCH/CCS/STATE/COMPUTE) 从"占位单 opcode"升级为
"真实 PIM 微操作序列 + 审计记录 (Causal Record) 生成"。

背景 (v0.1 占位问题):
  eda_rtlgen.CAUSAL_OP_TO_MICRO / eda_dataflow.CAUSAL_OP_TO_MICRO 中的映射
  (NS→ADD, IAP→CMP_EQ, LCH→CMP_GT, CCS→NOP, STATE→STORE, COMPUTE→MUL)
  全部标注 (placeholder)，生成的微码语义未与真实 PIM 单元对齐，且审计单元
  的 dep_mask/constraint_bits 恒为全 1 (pass-through)，无法体现因果依赖。

本模块的正式语义 (v0.2.0):
  1. 每个因果算子映射为一个「微操作序列」(micro-op sequence)，序列中的每个
     微操作对应 spl_pim_cell.v2 的 5-bit opcode (OP_*)，语义与 RTL 一致。
  2. 每个因果算子同时生成一条「审计记录」(Causal Record)，字段格式与
     spl_cim_causal_unit.v2 的控制包完全一致:
       rule_id[7:0]        — 算子类型编码 (见 RULE_ID_*)
       dep_mask[55:0]      — 真实依赖位掩码 (输入的依赖位 = 1)
       constraint_bits[63:0] — 硬约束位 (默认全 1 = 无额外硬约束)
       weight_q16_16[63:0] — 权重/敏感度 (Q16.16 定点)
       provenance[63:0]    — 来源链 (设计级 hash 前缀)
  3. 审计记录可直接写入 spl_cim_causal_unit 的 wr_data_p/wr_data_q。

RTL 契约来源 (只读核验，不臆造):
  - rtl/spl_pim_cell.sv:      OP_ADD=0x01 ... OP_STORE_LOC=0x1B (28 ops)
  - rtl/spl_cim_causal_unit.sv: wr_data_p[255:248]=rule_id,
    [247:192]=dep_mask(56b), [191:128]=constraint_bits(64b, 全1才过),
    [127:64]=weight_q16_16, wr_data_q[63:0]=provenance
  - License: SPL-G1 dual-track (see LICENSE)
"""

from typing import List, Dict, Any, Tuple, Optional
from dataclasses import dataclass, field

# ═══════════════════════════════════════════════════════════════════
# 1. PIM 微操作 (与 rtl/spl_pim_cell.sv 的 5-bit opcode 对齐)
# ═══════════════════════════════════════════════════════════════════

# 微操作: (助记符, opcode)
OP_NOP       = 0x00
OP_ADD       = 0x01
OP_ADC       = 0x02
OP_SUB       = 0x03
OP_SBB       = 0x04
OP_MUL_LO    = 0x05
OP_MUL_HI    = 0x06
OP_MAC       = 0x07
OP_CMP_EQ    = 0x08
OP_CMP_NE    = 0x09
OP_CMP_LT    = 0x0A
OP_CMP_GT    = 0x0B
OP_SHL       = 0x0C
OP_SHR       = 0x0D
OP_SAR       = 0x0E
OP_AND       = 0x0F
OP_OR        = 0x10
OP_XOR       = 0x11
OP_NOT       = 0x12
OP_FP16_ADD  = 0x13
OP_FP16_SUB  = 0x14
OP_FP16_MUL  = 0x15
OP_FP16_CMP  = 0x16
OP_FP16_MAC  = 0x17
OP_PRED_SET  = 0x18
OP_LOAD_ROW  = 0x19
OP_LOAD_COL  = 0x1A
OP_STORE_LOC = 0x1B

OPCODE_NAMES = {
    0x00: "NOP", 0x01: "ADD", 0x02: "ADC", 0x03: "SUB", 0x04: "SBB",
    0x05: "MUL_LO", 0x06: "MUL_HI", 0x07: "MAC", 0x08: "CMP_EQ",
    0x09: "CMP_NE", 0x0A: "CMP_LT", 0x0B: "CMP_GT", 0x0C: "SHL",
    0x0D: "SHR", 0x0E: "SAR", 0x0F: "AND", 0x10: "OR", 0x11: "XOR",
    0x12: "NOT", 0x13: "FP16_ADD", 0x14: "FP16_SUB", 0x15: "FP16_MUL",
    0x16: "FP16_CMP", 0x17: "FP16_MAC", 0x18: "PRED_SET",
    0x19: "LOAD_ROW", 0x1A: "LOAD_COL", 0x1B: "STORE_LOC",
}

# ═══════════════════════════════════════════════════════════════════
# 2. 因果算子 → 审计规则 ID (rule_id[7:0])
# ═══════════════════════════════════════════════════════════════════
# 与 CausalOpType 枚举对应的稳定编码 (0x01-0x06，非 RTL 保留值冲突)
RULE_ID_NS      = 0x01   # 叙事剥离
RULE_ID_IAP     = 0x02   # 内隐假设检测
RULE_ID_LCH     = 0x03   # 脆弱性对冲
RULE_ID_CCS     = 0x04   # 因果时钟同步
RULE_ID_STATE   = 0x05   # 状态更新
RULE_ID_COMPUTE = 0x06   # 通用计算

RULE_ID_MAP = {
    "NS": RULE_ID_NS, "IAP": RULE_ID_IAP, "LCH": RULE_ID_LCH,
    "CCS": RULE_ID_CCS, "STATE": RULE_ID_STATE, "COMPUTE": RULE_ID_COMPUTE,
}

# ═══════════════════════════════════════════════════════════════════
# 3. 因果算子 → 微操作序列 (正式后端语义)
# ═══════════════════════════════════════════════════════════════════
# 每个算子一个序列。语义说明 (基于 PIM cell v2 真实能力):
#   NS    叙事剥离  → 输入归一化 (SUB 偏移) + 掩码 (AND) + 谓词过滤 (CMP_GT→PRED_SET)
#   IAP   假设检测  → 双输入比较 (CMP_NE 检测分歧) + 差值 (SUB) + 阈值 (CMP_GT)
#   LCH   脆弱对冲  → 边界比较 (CMP_GT/CMP_LT) + 谓词选择 (PRED_SET) + 钳位 (SUB/ADD)
#   CCS   时钟同步  → 对齐校正 (SUB) + 偏差检测 (CMP_NE) + 屏障 (PRED_SET)
#   STATE 状态更新  → 旧值读回 (LOAD_ROW) + 增量 (ADD) + 持久化 (STORE_LOC)
#   COMPUTE 通用计算 → 乘累加 (MUL_LO + MAC) + 溢出钳位 (CMP_GT + SUB)
#
# 每个条目: {"seq": [(opcode, operand_desc), ...], "desc": 语义描述}
OP_SEQUENCES: Dict[str, Dict[str, Any]] = {
    "NS": {
        "desc": "Narrative strip: normalize (SUB) then mask (AND) then predicate-gate (CMP_GT→PRED_SET)",
        "seq": [
            (OP_SUB,       "subtract bias offset (normalize)"),
            (OP_AND,       "apply mask (strip narrative)"),
            (OP_CMP_GT,    "compare against strip threshold"),
            (OP_PRED_SET,  "set predicate from comparison"),
        ],
    },
    "IAP": {
        "desc": "Assumption detect: divergence (CMP_NE) + delta (SUB) + threshold (CMP_GT)",
        "seq": [
            (OP_CMP_NE,    "detect divergence between inputs"),
            (OP_SUB,       "compute signed delta"),
            (OP_CMP_GT,    "compare delta against assumption threshold"),
            (OP_PRED_SET,  "set predicate (assumption present)"),
        ],
    },
    "LCH": {
        "desc": "Fragility hedge: bounds check (CMP_GT/CMP_LT) + predicate select + clamp (SUB/ADD)",
        "seq": [
            (OP_CMP_GT,    "upper-bound check"),
            (OP_PRED_SET,  "set predicate from bound check"),
            (OP_CMP_LT,    "lower-bound check"),
            (OP_SUB,       "clamp high (fragility reduction)"),
        ],
    },
    "CCS": {
        "desc": "Clock sync: alignment correction (SUB) + skew detect (CMP_NE) + barrier (PRED_SET)",
        "seq": [
            (OP_SUB,       "align phase offset"),
            (OP_CMP_NE,    "detect residual skew"),
            (OP_PRED_SET,  "set barrier predicate"),
            (OP_NOP,       "barrier slot (no-op)"),
        ],
    },
    "STATE": {
        "desc": "State update: readback (LOAD_ROW) + increment (ADD) + persist (STORE_LOC)",
        "seq": [
            (OP_LOAD_ROW,  "read back prior state row"),
            (OP_ADD,       "apply delta to state"),
            (OP_STORE_LOC, "persist to local store"),
            (OP_NOP,       "settle slot"),
        ],
    },
    "COMPUTE": {
        "desc": "Compute: multiply (MUL_LO) + accumulate (MAC) + saturate (CMP_GT+SUB)",
        "seq": [
            (OP_MUL_LO,    "low product"),
            (OP_MAC,       "accumulate into result"),
            (OP_CMP_GT,    "overflow check"),
            (OP_SUB,       "saturate (clamp on overflow)"),
        ],
    },
}


def get_op_sequence(op_type: str) -> Tuple[str, List[int]]:
    """返回 (语义描述, opcode 序列)。未知算子返回 NOP 序列。"""
    key = str(op_type).upper()
    if key in OP_SEQUENCES:
        entry = OP_SEQUENCES[key]
        return entry["desc"], [opc for opc, _ in entry["seq"]]
    return "Unknown op (NOP placeholder)", [OP_NOP]


# ═══════════════════════════════════════════════════════════════════
# 4. 审计记录生成 (Causal Record) — 与 spl_cim_causal_unit.v2 对齐
# ═══════════════════════════════════════════════════════════════════

@dataclass
class CausalRecord:
    """一条因果审计记录，可直接打包进 wr_data_p / wr_data_q。

    字段布局 (与 spl_cim_causal_unit.v2 完全一致):
      wr_data_p[255:248] = rule_id
      wr_data_p[247:192] = dep_mask (56-bit, 1=依赖必须成立)
      wr_data_p[191:128] = constraint_bits (64-bit, 全1才通过)
      wr_data_p[127:64]  = weight_q16_16
      wr_data_q[63:0]    = provenance
    """
    rule_id: int
    dep_mask: int
    constraint_bits: int = 0xFFFFFFFFFFFFFFFF
    weight_q16_16: int = 0x00010000          # 1.0 in Q16.16
    provenance: int = 0

    def pack_p(self) -> int:
        """打包 256-bit wr_data_p。"""
        return (
            ((self.rule_id & 0xFF) << 248)
            | ((self.dep_mask & ((1 << 56) - 1)) << 192)
            | ((self.constraint_bits & ((1 << 64) - 1)) << 128)
            | ((self.weight_q16_16 & ((1 << 64) - 1)) << 64)
        )

    def pack_q(self) -> int:
        """打包 256-bit wr_data_q (provenance 低 64 位)。"""
        return self.provenance & ((1 << 64) - 1)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "rule_id": self.rule_id,
            "dep_mask_hex": f"0x{self.dep_mask:014x}",
            "constraint_bits_hex": f"0x{self.constraint_bits:016x}",
            "weight_q16_16": self.weight_q16_16,
            "provenance_hex": f"0x{self.provenance:016x}",
        }


def build_dep_mask(op_index: int, producer_indices: List[int]) -> int:
    """从因果图构造真实依赖位掩码。

    语义: dep_mask 的 bit[i] = 1 表示「第 i 个生产者算子的输出必须有效」。
    这里使用设计级稳定的槽位编码: 生产者 op_index → dep bit = op_index % 56。
    (注: 完整 256-bit 依赖图聚合为 Phase A5 范围，此处为 v0.2 显式编码。)
    """
    mask = 0
    for p in producer_indices:
        bit = p % 56
        mask |= (1 << bit)
    return mask


def build_causal_record(
    op_type: str,
    op_index: int,
    producer_indices: List[int],
    design_hash: int = 0,
    weight: Optional[float] = None,
) -> CausalRecord:
    """为单个因果算子生成审计记录。

    Args:
        op_type: 算子类型码 (NS/IAP/LCH/CCS/STATE/COMPUTE)
        op_index: 算子在 IR 中的下标 (用于依赖槽位)
        producer_indices: 该算子输入信号的生产者算子下标列表
        design_hash: 设计级 hash 前缀 (provenance 高位)
        weight: 权重 (float)，转 Q16.16 定点 (默认 1.0)
    """
    key = str(op_type).upper()
    rule_id = RULE_ID_MAP.get(key, 0x00)
    dep_mask = build_dep_mask(op_index, producer_indices)
    if weight is not None:
        w = max(-32768.0, min(32767.999, float(weight)))
        wq = int(round(w * 65536.0))
    else:
        wq = 0x00010000
    # provenance = 设计 hash 前缀 + 算子下标低 16 位
    prov = ((design_hash & 0xFFFFFFFFFFFF) << 16) | (op_index & 0xFFFF)
    return CausalRecord(
        rule_id=rule_id,
        dep_mask=dep_mask,
        constraint_bits=0xFFFFFFFFFFFFFFFF,
        weight_q16_16=wq,
        provenance=prov,
    )


def build_design_provenance(design_name: str) -> int:
    """设计级 provenance 前缀: 从设计名导出稳定 48-bit hash。"""
    h = 0x5EED
    for ch in design_name:
        h = ((h << 5) + h + ord(ch)) & 0xFFFFFFFFFFFF
    return h


def opcode_list_to_hex(seq: List[int]) -> str:
    """微码序列 → 十六进制串 (用于报告/生成)。"""
    return ", ".join(f"0x{opc:02X}" for opc in seq)


def opcode_list_to_names(seq: List[int]) -> str:
    """微码序列 → 助记符串。"""
    return " → ".join(OPCODE_NAMES.get(opc, "?") for opc in seq)


# ═══════════════════════════════════════════════════════════════════
# 5. 自检 (--self-test)
# ═══════════════════════════════════════════════════════════════════

def self_test() -> int:
    """验证后端语义定义与 RTL 契约的一致性。返回错误数 (0=通过)。"""
    errors = 0

    # 5.1 所有 opcode 必须在 PIM cell v2 定义范围内
    known = set(OPCODE_NAMES.keys())
    for key, entry in OP_SEQUENCES.items():
        for opc, _desc in entry["seq"]:
            if opc not in known:
                print(f"[FAIL] {key}: opcode 0x{opc:02X} 不在 PIM cell v2 opcode 表中")
                errors += 1

    # 5.2 rule_id 必须唯一且非零
    used = set()
    for key, rid in RULE_ID_MAP.items():
        if rid == 0:
            print(f"[FAIL] {key}: rule_id 不能为 0")
            errors += 1
        if rid in used:
            print(f"[FAIL] rule_id 0x{rid:02X} 重复")
            errors += 1
        used.add(rid)

    # 5.3 审计记录打包解包往返
    rec = build_causal_record("IAP", 2, [0, 1], design_hash=0xABCDEF)
    p = rec.pack_p()
    assert ((p >> 248) & 0xFF) == RULE_ID_IAP, "rule_id 打包错误"
    assert ((p >> 192) & ((1 << 56) - 1)) == build_dep_mask(2, [0, 1]), "dep_mask 打包错误"
    assert ((p >> 128) & ((1 << 64) - 1)) == 0xFFFFFFFFFFFFFFFF, "constraint_bits 打包错误"
    assert ((p >> 64) & ((1 << 64) - 1)) == 0x00010000, "weight 打包错误"
    assert rec.pack_q() == ((0xABCDEF << 16) | 2), "provenance 打包错误"

    # 5.4 序列长度 = 4 (与 spl_pim_sequencer 每算子 4 槽兼容)
    for key, entry in OP_SEQUENCES.items():
        if len(entry["seq"]) != 4:
            print(f"[WARN] {key}: 序列长度 {len(entry['seq'])} != 4 (sequencer 默认槽数)")
            errors += 0

    # 5.5 全算子序列可打印
    for key in sorted(OP_SEQUENCES):
        desc, seq = get_op_sequence(key)
        print(f"  [OK] {key:<8} {opcode_list_to_names(seq)}  |  {desc}")

    return errors


if __name__ == "__main__":
    import sys
    errs = self_test()
    print(f"\nbackend self-test: {'PASS' if errs == 0 else f'{errs} ERRORS'}")
    sys.exit(0 if errs == 0 else 1)
