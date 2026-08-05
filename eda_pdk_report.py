"""
SP-EDA 材料工艺库覆盖报告器 (Stage 3, v0.1.0)

只读工具：扫描 pdk/ 目录下所有 PDK JSON，输出：
  1. 算子覆盖矩阵 — 每种材料是否提供 6 种因果算子的工艺变体
  2. 4 维数值域 — 每种材料每个算子的 delay/power/area/snr 范围
  3. 帕累托对比表 — 用统一的"全设计合计"维度对比各材料

用法：
  python eda_pdk_report.py [--pdk-dir pdk]
  python eda_pdk_report.py --json   # 输出机器可读 JSON

注意：本工具不加载工艺库（无副作用），仅解析 PDK JSON 文件。
"""

import argparse
import glob
import json
import os
import sys

OP_TYPES = ["NS", "IAP", "LCH", "CCS", "STATE", "COMPUTE"]
METRICS = ["delay_ns", "power_mw", "area_um2", "snr_db"]


def scan_pdk(file_path: str) -> dict:
    """解析单个 PDK 文件，返回结构化摘要。"""
    with open(file_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    material = data.get("material", os.path.basename(file_path))
    cells = data.get("cells", {})

    op_coverage = {op: False for op in OP_TYPES}
    op_variants = {op: {"delay_ns": [], "power_mw": [], "area_um2": [], "snr_db": [],
                        "cell_types": []} for op in OP_TYPES}

    for op_str, variants in cells.items():
        op_key = op_str.upper()
        if op_key not in OP_TYPES:
            continue
        if variants:
            op_coverage[op_key] = True
        for v in variants:
            for m in METRICS:
                val = v.get(m)
                if val is not None:
                    op_variants[op_key][m].append(float(val))
            cell_type = v.get("implementation_spec", {}).get("cell_type", "?")
            op_variants[op_key]["cell_types"].append(cell_type)

    # 数值域：min/max
    ranges = {}
    for op in OP_TYPES:
        ranges[op] = {
            m: (_fmt(min(op_variants[op][m])), _fmt(max(op_variants[op][m])))
            if op_variants[op][m] else ("—", "—")
            for m in METRICS
        }

    return {
        "material": material,
        "file": os.path.basename(file_path),
        "coverage": op_coverage,
        "num_variants": sum(1 for op in OP_TYPES for _ in op_variants[op]["cell_types"]),
        "cell_types": op_variants,
        "ranges": ranges,
        "has_placeholder": "占位" in data.get("note", "") or "placeholder" in data.get("note", "").lower(),
    }


def _fmt(v: float) -> str:
    return f"{v:g}"


def print_matrix(pdks: list) -> None:
    print("=" * 78)
    print("  SPL-G1 材料工艺库覆盖矩阵 (Stage 3)")
    print("=" * 78)
    print(f"{'材料':<28}{'文件':<28}{'变体数':>6}  覆盖算子")
    print("-" * 78)
    for p in pdks:
        covered = [op for op in OP_TYPES if p["coverage"][op]]
        missing = [op for op in OP_TYPES if not p["coverage"][op]]
        flag = "OK " if not missing else f"缺 {','.join(missing)}"
        placeholder = " [占位]" if p["has_placeholder"] else ""
        print(f"{p['material']:<28}{p['file']:<28}{p['num_variants']:>6}  {flag}{placeholder}")
    print()


def print_ranges(pdks: list) -> None:
    print("=" * 78)
    print("  4 维数值域 (min~max, 按算子)")
    print("=" * 78)
    for p in pdks:
        print(f"\n>> {p['material']} ({p['file']})")
        print(f"  {'算子':<10}{'delay_ns':<16}{'power_mw':<16}{'area_um2':<16}{'snr_db':<12}  实现")
        for op in OP_TYPES:
            r = p["ranges"][op]
            ct = ",".join(p["cell_types"][op]["cell_types"]) if p["cell_types"][op]["cell_types"] else "—"
            print(f"  {op:<10}{r['delay_ns'][0]:>6}~{r['delay_ns'][1]:<9}"
                  f"{r['power_mw'][0]:>6}~{r['power_mw'][1]:<9}"
                  f"{r['area_um2'][0]:>7}~{r['area_um2'][1]:<8}"
                  f"{r['snr_db'][0]:>6}~{r['snr_db'][1]:<5}  {ct}")
    print()


def main() -> int:
    parser = argparse.ArgumentParser(description="SPL-G1 材料工艺库覆盖报告器")
    parser.add_argument("--pdk-dir", default="pdk", help="PDK 目录（默认 pdk/）")
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    args = parser.parse_args()

    if not os.path.isdir(args.pdk_dir):
        print(f"[错误] PDK 目录不存在: {args.pdk_dir}", file=sys.stderr)
        return 1

    pdk_files = sorted(glob.glob(os.path.join(args.pdk_dir, "*.json")))
    if not pdk_files:
        print(f"[错误] {args.pdk_dir}/ 下没有 PDK JSON 文件", file=sys.stderr)
        return 1

    pdks = []
    for f in pdk_files:
        try:
            pdks.append(scan_pdk(f))
        except (json.JSONDecodeError, IOError) as e:
            print(f"[错误] 解析 {f} 失败: {e}", file=sys.stderr)

    if args.json:
        print(json.dumps(pdks, ensure_ascii=False, indent=2))
        return 0

    print_matrix(pdks)
    print_ranges(pdks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
