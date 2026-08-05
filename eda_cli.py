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
import json

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
        "--desc",
        help="因果描述 JSON 文件路径"
    )
    parser.add_argument(
        "--pdk",
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
    # ── Stage 1: EDA→RTL 三缝打通 ──
    parser.add_argument(
        "--rtl", action="store_true",
        help="生成 RTL 工件（spl_config_pkg.sv / tb_eda_stimulus.sv / syn_tcl.tcl）到 outputs/rtlgen/"
    )
    parser.add_argument(
        "--apply-rtl", action="store_true",
        help="将生成的 spl_config_pkg.sv 覆盖到 rtl/（G1_Top 的配置钩子生效，需配合 --rtl）"
    )
    parser.add_argument(
        "--rows", type=int, default=64,
        help="PIM 阵列行数（写入 spl_config_pkg，默认 64，对应 G1_Top v6/Phase B）"
    )
    parser.add_argument(
        "--cols", type=int, default=64,
        help="PIM 阵列列数（写入 spl_config_pkg，默认 64，对应 G1_Top v6/Phase B）"
    )
    # ── Stage 3: 多材料菜单显性化 ──
    parser.add_argument(
        "--multi-pdk", action="store_true",
        help="扫描 --pdk-dir 下所有 PDK，对同一设计逐一映射并输出帕累托对比表（Stage 3）"
    )
    parser.add_argument(
        "--pdk-dir", default="pdk",
        help="多材料批量模式下的 PDK 目录（默认 pdk/，需配合 --multi-pdk）"
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


def _pareto(results) -> list:
    """返回帕累托前沿（多目标最小化 delay/power/area，最大化 snr）。

    A 支配 B：A 的所有目标不劣于 B 且至少一个严格更优
    （delay/power/area 越小越好，snr 越大越好）。
    """
    pareto = []
    for i, (ma, ra) in enumerate(results):
        dominated = False
        for j, (mb, rb) in enumerate(results):
            if i == j:
                continue
            # b 不劣于 a 在所有目标上，且至少一个严格更好 → a 被支配
            not_worse = (rb.total_delay_ns <= ra.total_delay_ns and
                         rb.total_power_mw <= ra.total_power_mw and
                         rb.total_area_um2 <= ra.total_area_um2 and
                         rb.min_snr_db >= ra.min_snr_db)
            strictly_better = (rb.total_delay_ns < ra.total_delay_ns or
                               rb.total_power_mw < ra.total_power_mw or
                               rb.total_area_um2 < ra.total_area_um2 or
                               rb.min_snr_db > ra.min_snr_db)
            if not_worse and strictly_better:
                dominated = True
                break
        if not dominated:
            pareto.append((ma, ra))
    return pareto


def main():
    parser = build_argument_parser()
    args = parser.parse_args()

    if args.print_format:
        print_format_help()
        return 0

    if args.multi_pdk and (not args.desc or not args.pdk_dir):
        print("[错误] --multi-pdk 需要 --desc 指定设计", file=sys.stderr)
        return 1
    if not args.multi_pdk and (not args.desc or not args.pdk):
        print("[错误] 需要 --desc 与 --pdk", file=sys.stderr)
        return 1

    # === Step 1: 解析因果描述（两模式共用） ===
    print(f"\n[解析] 读取 {args.desc} ...")
    try:
        ir = parse_causal_description(args.desc)
    except ParserError as e:
        print(f"[解析错误] {e}", file=sys.stderr)
        return 1

    print(describe_ir(ir))
    ir.validate()
    print("[解析] CausalIR 校验通过")

    # === Step 0: 加载 PDK（单材料模式） ===
    if not args.multi_pdk:
        print(f"[PDK] 加载 {args.pdk} ...")
        MaterialLibrary.clear_library()
        pdk_abs = os.path.abspath(args.pdk)
        pdk_dir = os.path.dirname(pdk_abs)
        MaterialLibrary.set_allowed_pdk_dir(pdk_dir)
        try:
            MaterialLibrary.load_from_pdk_file(pdk_abs)
        except Exception as e:
            print(f"[错误] PDK 加载失败: {e}", file=sys.stderr)
            return 1
        if args.material:
            material = args.material
        else:
            with open(args.pdk, 'r', encoding='utf-8') as f:
                pdk_data = json.load(f)
            material = pdk_data.get("material", "generic")
            print(f"[INFO] 自动检测材料: {material}")
            print(f"       可用算子: {', '.join(sorted(pdk_data.get('cells', {}).keys()))}")

    constraints = load_constraints(args)
    strategy = MappingStrategy(args.strategy)

    # === Step 3.5: 多材料批量对比（Stage 3） ===
    if args.multi_pdk:
        import glob as _glob
        pdk_files = sorted(_glob.glob(os.path.join(args.pdk_dir, "*.json")))
        if not pdk_files:
            print(f"[错误] {args.pdk_dir}/ 下没有 PDK JSON", file=sys.stderr)
            return 1

        print(f"\n===== 多材料批量对比: {ir.name} =====")
        results = []
        for pf in pdk_files:
            try:
                MaterialLibrary.clear_library()
                MaterialLibrary.set_allowed_pdk_dir(os.path.dirname(os.path.abspath(pf)))
                MaterialLibrary.load_from_pdk_file(pf)
            except Exception as e:
                print(f"[错误] 加载 {pf} 失败: {e}", file=sys.stderr)
                continue
            with open(pf, 'r', encoding='utf-8') as f:
                mat = json.load(f).get("material", os.path.basename(pf))
            try:
                res = map_causal_ir(ir, mat, load_constraints(args), strategy)
                results.append((mat, res))
                print(f"  [{mat}] ok={res.all_passed} "
                      f"delay={res.total_delay_ns:.1f}ns power={res.total_power_mw:.1f}mW "
                      f"area={res.total_area_um2:.1f}um2 snr={res.min_snr_db:.1f}dB "
                      f"unmapped={res.unmapped_count}")
            except Exception as e:
                print(f"  [{mat}] 映射失败: {e}", file=sys.stderr)

        # 帕累托对比表
        if results:
            print("\n── 帕累托对比（多目标最小化 delay/power/area；SNR 最大化） ──")
            print(f"  {'材料':<28}{'delay(ns)':>10}{'power(mW)':>10}{'area(um2)':>11}{'snr(dB)':>9}  帕累托")
            pareto = _pareto(results)
            for mat, res in results:
                mark = "★" if (mat, res) in pareto else " "
                print(f"  {mat:<28}{res.total_delay_ns:>10.1f}{res.total_power_mw:>10.1f}"
                      f"{res.total_area_um2:>11.1f}{res.min_snr_db:>9.1f}  {mark}")
            print("\n  ★ = 帕累托前沿（无其他材料在所有指标上同时更优）")
        return 0 if all(r[1].all_passed for r in results) else 1

    # === 单材料模式：Step 2 映射 + Step 3 输出 + Step 4 RTL 生成 ===
    print(f"\n[映射] 材料={material} 策略={strategy.value}")
    result = map_causal_ir(ir, material, constraints, strategy)

    export_and_report(
        result,
        output_path=args.output,
        print_report=True
    )

    if args.rtl:
        from eda_rtlgen import generate_rtl_artifacts, print_rtl_summary
        artifacts = generate_rtl_artifacts(
            result,
            array_rows=args.rows,
            array_cols=args.cols,
            ir=ir
        )
        print_rtl_summary(result, artifacts)

        if args.apply_rtl:
            import shutil
            src = artifacts["config_pkg"]
            dst = os.path.join("rtl", "spl_config_pkg.sv")
            shutil.copyfile(src, dst)
            print(f"[RTL] spl_config_pkg.sv 已应用到 {os.path.abspath(dst)}")
            print(f"      G1_Top_Integrated 将在下次编译时读取该配置（行={args.rows} 列={args.cols}）")

    return 0 if result.all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
