# SPL-G1 EDA 迭代方案执行报告（阶段 0-5）

日期：2026-08-05
基线：docs/BASELINE.md（阶段 0）

## 总命题达成

**从"多材料设计权衡报告器"迭代为"因果感知的 PIM 编译后端"**——判据（映射结果可落地成可综合 RTL 并被仿真验证）已通过硬验证。

## 阶段执行记录

| 阶段 | 目标 | 改动 | 硬验证 |
|---|---|---|---|
| 0 基线 | 量尺子 | docs/BASELINE.md | 3 演示全 PASS，6/6 映射 |
| 1 三缝打通 | EDA→RTL 闭环 | `G1_Top` import `spl_config_pkg`；stimulus 按数据依赖生成；syn_tcl 动态收集 | 生成物与 RTL 编译通过 |
| 2 数据流真实化 | 因果边→RA-BUS 序列 | `eda_dataflow.py`（cell 分配器 + 读回-传递-执行） | `[PASS] EDA stimulus completed, 0 errors` |
| 3 多材料菜单 | 覆盖矩阵 + 帕累托 | `eda_pdk_report.py` + `--multi-pdk` | 覆盖矩阵 + 帕累托前沿输出 |
| 4 单片混装 | per-op 材料分派 | `CausalOp.material` + mapper 按 op 查变体 + 边界预算 | `单片混装: 2 种材料, 跨材料边界: 3 条` |
| 5 splcc 并轨 | 三岔流水线汇合 | `splcc_bridge.py` → tb_unified.sv | `[PASS] microcode executed, fuse intact, 0 errors` |

## 新增/修改文件

### 新增
- `eda_dataflow.py` — Stage 2：数据流感知 cell 分配器 + 执行计划
- `eda_pdk_report.py` — Stage 3：材料工艺库覆盖报告器（只读）
- `splcc_bridge.py` — Stage 5：splcc↔EDA 汇合桥
- `examples/heterogeneous_demo.json` — Stage 4：单片硅光混装示例
- `rtl/spl_config_pkg.sv` — Stage 1：EDA→RTL 配置钩子（默认 64×64）
- `docs/BASELINE.md`、`docs/EDA_ITERATION_DONE.md`

### 修改
- `eda_rtlgen.py` — 三缝打通 + 数据流 stimulus + 修复 enum 生成 bug
- `eda_cli.py` — `--rtl/--apply-rtl/--rows/--cols/--multi-pdk/--pdk-dir`
- `eda_parser.py` — per-op `material` 字段
- `eda_mapper.py` — 按 op 维度材料分派 + 异构边界预算
- `EDA_fixed.py` — `CausalOp.material` 字段
- `G1_Top_Integrated.sv` — `import spl_config_pkg`，阵列几何 EDA 驱动
- `Makefile` — 新增 `pdk-report/multi-pdk/rtlgen/rtlgen-apply/demo-hetero/splcc-bridge`

## 关键验证结果

### 1. EDA stimulus 在真实 RTL 上执行（阶段 1+2）
```
===== EDA Stimulus: causal_chain_demo =====
Material: silicon_cim_28nm_v1 | Strategy: min_delay
Total ops: 6 | Mapped: 6
[PASS] EDA stimulus completed: array stable, fuse intact
===== Results: 0 errors =====
```

### 2. 单片混装边界预算（阶段 4）
```
单片混装: 2 种材料 (optical + silicon)
跨材料边界: 3 条数据边需接口转换 [optical→silicon:2, silicon→optical:1]
```

### 3. splcc microcode 汇合（阶段 5）
```
[PASS] microcode executed, fuse intact (cycles=60)
===== Results: 0 errors =====
```

## 遗留真空（诚实标注）

1. **micro-op 语义是占位**：NS→ADD、IAP→CMP_EQ 等映射待 Phase A5 NOMOS 约束规则精确定义。
2. **PDK 数值仍为占位**：阶段 6 需晶圆厂实测值，属外部依赖。
3. **optical PDK 算子覆盖不全**：覆盖矩阵显示缺 NS/LCH 变体，混装演示正确暴露。
4. **`make sim` 原始 9 测试**在 Windows 下未通过 make 实跑（无 make），用等价 iverilog 命令验证。
5. 阶段 2 的 cell 分配器是数据流感知（行优先拓扑），尚未做物理邻近优化（8-bit 邻居互连利用率未统计）。

## 使用方式

```bash
make pdk-report          # 材料覆盖矩阵
make multi-pdk           # 多材料帕累托对比
make rtlgen              # EDA→RTL 生成（outputs/rtlgen/）
make rtlgen-apply        # 应用配置到 rtl/spl_config_pkg.sv
make demo-hetero         # 单片混装演示
make splcc-bridge        # splcc microcode 汇合
```
