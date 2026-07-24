"""
SP-EDA 命令行入口 (v0.1.0)

将因果描述编译映射为硬件网表的一站式 CLI。

用法:
  python eda_cli.py --desc <因果描述.json> --pdk <工艺库.json> [选项]

示例:
  python eda_cli.py --desc examples/causal_chain_demo.json \
                    --pdk pdk/optical_mzi_photonics_v1.json \
                    --material optical_mzi_photonics_v1 \
                    --strategy min_delay \
                    --output netlist.json
"""

import argparse
import sys
import os

from EDA_fixed import (
    PhysicalConstraints, MaterialLibrary,
    REVERSE_OP_MAPPING
)
from eda_parser import parse_causal_description, describe_ir, ParserError
from eda_mapper import map_causal_ir, MappingStrategy, MappingResult
from eda_exporter import export_and_report
from eda_rtlgen import generate_rtl_artifacts, print_rtl_summary


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="SP-EDA 跨材料因果编译器前端",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
约束文件格式 (JSON):
  {
    "max_delay_ns": 1.5,
    "max_power_mw": 30.0,
    "max_area_um2": 500.0,
    "min_snr_db": 25.0
  }

因果描述格式见文档或使用 --print-format 查看。
        """
    )

    parser.add_argument(
        "--desc", required=True,
        help="因果描述 JSON 文件路径"
    )
    parser.add_argument(
        "--pdk", required=True,
        help="PDK 工艺库 JSON 文件路径"
    )
    parser.add_argument(
        "--material", default=None,
        help="目标材料名称（默认从 PDK 文件自动检测）"
    )
    parser.add_argument(
        "--constraints",
        help="物理约束 JSON 文件路径（与 --max-delay 等互斥）"
    )
    parser.add_argument(
        "--max-delay", type=float, default=10.0,
        help="最大延迟 ns（默认 10.0）"
    )
    parser.add_argument(
        "--max-power", type=float, default=100.0,
        help="最大功耗 mW（默认 100.0）"
    )
    parser.add_argument(
        "--max-area", type=float, default=1e6,
        help="最大面积 um2（默认 1e6）"
    )
    parser.add_argument(
        "--min-snr", type=float, default=20.0,
        help="最小信噪比 dB（默认 20.0）"
    )
    parser.add_argument(
        "--strategy", default="min_delay",
        choices=["first_fit", "min_delay", "min_power", "min_area"],
        help="映射策略（默认 min_delay）"
    )
    parser.add_argument(
        "--output", default=None,
        help="网表输出 JSON 文件路径（不指定则仅打印报告）"
    )
    parser.add_argument(
        "--print-format", action="store_true",
        help="打印因果描述 JSON 格式说明并退出"
    )

    return parser


def print_format_help():
    print("""
因果描述 JSON 格式:
{
  "design_name": "my_design",
  "inputs": ["signal_a", "signal_b"],
  "outputs": ["result"],
  "operators": [
    {
      "op_type": "NS",
      "inputs": ["signal_a"],
      "outputs": ["stripped_a"],
      "params": {}
    },
    {
      "op_type": "IAP",
      "inputs": ["stripped_a", "signal_b"],
      "outputs": ["assumptions"],
      "params": {"depth": 3}
    }
  ]
}

合法 op_type: NS, IAP, LCH, CCS, STATE
""")


def load_constraints(args) -> PhysicalConstraints:
    """从 CLI 参数或约束文件构建 PhysicalConstraints"""
    if args.constraints:
        import json
        with open(args.constraints, 'r', encoding='utf-8') as f:
            cdata = json.load(f)
        return PhysicalConstraints(
            material=args.material or "generic",
            max_delay_ns=cdata.get("max_delay_ns", 10.0),
            max_power_mw=cdata.get("max_power_mw", 100.0),
            max_area_um2=cdata.get("max_area_um2", 1e6),
            min_snr_db=cdata.get("min_snr_db", 20.0),
        )
    else:
        return PhysicalConstraints(
            material=args.material or "generic",
            max_delay_ns=args.max_delay,
            max_power_mw=args.max_power,
            max_area_um2=args.max_area,
            min_snr_db=args.min_snr,
        )


def main():
    parser = build_argument_parser()
    args = parser.parse_args()

    if args.print_format:
        print_format_help()
        return 0

    # === Step 0: 加载 PDK ===
    print(f"[PDK] 加载 {args.pdk} ...")
    MaterialLibrary.clear_library()

    # 设置 PDK 允许目录为 PDK 文件所在目录
    pdk_abs = os.path.abspath(args.pdk)
    pdk_dir = os.path.dirname(pdk_abs)
    MaterialLibrary.set_allowed_pdk_dir(pdk_dir)

    try:
        MaterialLibrary.load_from_pdk_file(pdk_abs)
    except Exception as e:
        print(f"[错误] PDK 加载失败: {e}", file=sys.stderr)
        return 1

    # 自动检测 material
    if args.material:
        material = args.material
    else:
        import json
        with open(args.pdk, 'r', encoding='utf-8') as f:
            pdk_data = json.load(f)
        material = pdk_data.get("material", "generic")
        print(f"[INFO] 自动检测材料: {material}")
        print(f"       可用算子: {', '.join(sorted(pdk_data.get('cells', {}).keys()))}")

    # === Step 1: 解析因果描述 ===
    print(f"\n[解析] 读取 {args.desc} ...")
    try:
        ir = parse_causal_description(args.desc)
    except ParserError as e:
        print(f"[解析错误] {e}", file=sys.stderr)
        return 1

    print(describe_ir(ir))
    ir.validate()
    print("[解析] CausalIR 校验通过")

    # === Step 2: 工艺映射 ===
    constraints = load_constraints(args)
    strategy = MappingStrategy(args.strategy)

    print(f"\n[映射] 材料={material} 策略={strategy.value}")
    result = map_causal_ir(ir, material, constraints, strategy)

    # === Step 3: 输出 ===
    export_and_report(
        result,
        output_path=args.output,
        print_report=True
    )

    return 0 if result.all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
