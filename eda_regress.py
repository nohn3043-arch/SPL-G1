"""
SPL-EDA 跨平台回归驱动 (v1.1.1)

纯 Python + subprocess，不依赖 GNU make，可在 Windows / Linux / macOS 一致运行。
遍历 设计(desc) × PDK(pdk) × 映射策略(strategy) 组合，逐个调用 `eda_cli.py`，
解析退出码与关键输出，产出 PASS/FAIL 矩阵并落盘。

对应路线图书 E-C5（跨平台回归）/ E-E5（测试夹具标准化）。

用法:
  python eda_regress.py                 # 跑全部 example + fixture × 全部 PDK × 全部策略
  python eda_regress.py --smoke         # 只跑 tests/fixtures（快速自检）
  python eda_regress.py --designs a b   # 仅指定若干设计（不含扩展名）
  python eda_regress.py --pdk-dir pdk   # 指定 PDK 目录
  python eda_regress.py --timeout 180   # 单用例超时秒数
"""

import argparse
import json
import os
import subprocess
import sys
import glob

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
STRATEGIES = ["first_fit", "min_delay", "min_power", "min_area"]
DESIGN_DIRS = ["examples", os.path.join("tests", "fixtures")]

# 已知脆弱用例：设计本身不走单 PDK 的 eda_cli 路径（需多材料/混装逻辑），
# 在单 PDK 回归下预期失败。列入此处后标记为 KNOWN-FAIL，不计入门禁失败，
# 但仍保留可见性，遵循仓库"诚实标注遗留真空"的约定。
KNOWN_FRAGILE = {
    "heterogeneous_demo": "per-op material 单片混装，需走 demo-hetero/多材料路径，单 PDK CLI 预期失败",
}


def _discover_designs(smoke_only, only):
    found = []
    for d in DESIGN_DIRS:
        pattern = os.path.join(REPO_ROOT, d, "*.json")
        for path in sorted(glob.glob(pattern)):
            name = os.path.splitext(os.path.basename(path))[0]
            if smoke_only and d != os.path.join("tests", "fixtures"):
                continue
            if only and name not in only:
                continue
            found.append((name, path))
    return found


def _discover_pdks(pdk_dir):
    pattern = os.path.join(REPO_ROOT, pdk_dir, "*.json")
    return sorted(glob.glob(pattern))


def _run_one(desc_path, pdk_path, strategy, out_path, timeout):
    cmd = [
        sys.executable, "eda_cli.py",
        "--desc", desc_path,
        "--pdk", pdk_path,
        "--strategy", strategy,
        "--output", out_path,
    ]
    try:
        proc = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT", ""
    except Exception as exc:  # noqa: BLE001
        return False, "ERROR:%s" % exc, ""

    rc = proc.returncode
    out = (proc.stdout or "") + (proc.stderr or "")
    # 退出码非 0 ⇒ 失败；0 ⇒ 通过（eda_cli 在 all_passed 时返回 0）
    if rc != 0:
        # 提取关键失败线索，便于定位
        reason = ""
        for marker in ("[错误]", "[解析错误]", "INCOMPATIBLE", "unmapped="):
            if marker in out:
                idx = out.find(marker)
                reason = out[idx:idx + 80].splitlines()[0]
                break
        if not reason:
            reason = "rc=%d" % rc
        return False, reason.strip(), out
    return True, "OK", out


def main():
    ap = argparse.ArgumentParser(description="SPL-EDA 跨平台回归驱动")
    ap.add_argument("--smoke", action="store_true", help="只跑 tests/fixtures 快速自检")
    ap.add_argument("--designs", nargs="*", default=None, help="仅指定若干设计名（不含扩展名）")
    ap.add_argument("--pdk-dir", default="pdk", help="PDK 目录（默认 pdk）")
    ap.add_argument("--timeout", type=int, default=120, help="单用例超时秒数（默认 120）")
    ap.add_argument("--out-dir", default=os.path.join("outputs", "regress"), help="结果输出目录")
    args = ap.parse_args()

    designs = _discover_designs(args.smoke, set(args.designs) if args.designs else None)
    pdks = _discover_pdks(args.pdk_dir)
    if not designs:
        print("[regress] 未发现任何设计 JSON", file=sys.stderr)
        return 2
    if not pdks:
        print("[regress] %s/ 下没有 PDK" % args.pdk_dir, file=sys.stderr)
        return 2

    out_dir = os.path.join(REPO_ROOT, args.out_dir)
    os.makedirs(out_dir, exist_ok=True)

    results = []  # (design, pdk, strategy, ok, reason, known)
    total = len(designs) * len(pdks) * len(STRATEGIES)
    done = 0
    print("===== SPL-EDA 回归 (v1.1.1) =====")
    print("设计 %d × PDK %d × 策略 %d = %d 用例" % (len(designs), len(pdks), len(STRATEGIES), total))

    for dname, dpath in designs:
        known_reason = KNOWN_FRAGILE.get(dname)
        for pdk_path in pdks:
            pdk_name = os.path.splitext(os.path.basename(pdk_path))[0]
            for strat in STRATEGIES:
                done += 1
                rname = "%s__%s__%s" % (dname, pdk_name, strat)
                out_path = os.path.join(out_dir, rname + ".json")
                ok, reason, _ = _run_one(dpath, pdk_path, strat, out_path, args.timeout)
                results.append((dname, pdk_name, strat, ok, reason, bool(known_reason)))
                if ok:
                    mark = "PASS"
                elif known_reason:
                    mark = "KNOWN-FAIL"
                else:
                    mark = "FAIL"
                print("[%3d/%3d] %-22s | %-28s | %-10s | %s" % (done, total, dname, pdk_name, strat, mark))

    passed = sum(1 for r in results if r[3])
    known_failed = sum(1 for r in results if not r[3] and r[5])
    unexpected_failed = sum(1 for r in results if not r[3] and not r[5])

    # 落盘矩阵
    matrix_txt = os.path.join(out_dir, "PASSFAIL_matrix.txt")
    summary = {
        "total": total,
        "passed": passed,
        "known_failed": known_failed,
        "unexpected_failed": unexpected_failed,
        "cases": [
            {"design": r[0], "pdk": r[1], "strategy": r[2],
             "pass": r[3], "known_fragile": r[5], "reason": ("" if r[3] else r[4])}
            for r in results
        ],
    }
    with open(matrix_txt, "w", encoding="utf-8") as f:
        f.write("SPL-EDA 回归矩阵  total=%d passed=%d known_fail=%d unexpected_fail=%d\n"
                % (total, passed, known_failed, unexpected_failed))
        for r in results:
            if r[3]:
                label = "PASS"
                note = ""
            elif r[5]:
                label = "KNOWN-FAIL"
                note = KNOWN_FRAGILE.get(r[0], "")
            else:
                label = "FAIL"
                note = r[4]
            f.write("%-22s | %-28s | %-10s | %-11s | %s\n" % (r[0], r[1], r[2], label, note))
    with open(os.path.join(out_dir, "regress_summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)

    print("\n===== 汇总: %d 用例 / PASS %d / KNOWN-FAIL %d / 门禁失败 %d ====="
          % (total, passed, known_failed, unexpected_failed))
    if known_failed:
        print("已知脆弱(忽略门禁):")
        for name in sorted(set(r[0] for r in results if not r[3] and r[5])):
            print("  - %s : %s" % (name, KNOWN_FRAGILE.get(name, "")))
    if unexpected_failed:
        print("门禁失败用例:")
        for r in results:
            if not r[3] and not r[5]:
                print("  - %s | %s | %s : %s" % (r[0], r[1], r[2], r[4]))
    print("矩阵: %s" % matrix_txt)
    # 门禁：仅"未预期失败"阻断发布；KNOWN-FAIL 不阻断（已诚实标注）
    return 1 if unexpected_failed else 0


if __name__ == "__main__":
    sys.exit(main())
