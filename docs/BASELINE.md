# SPL-G1 EDA 基线固化报告

日期：2026-08-05
状态：阶段 0 完成（EDA 链路实测）；RTL 仿真基线待补跑

## 1. 实测记录

### 1.1 EDA 演示链路（实跑 PASS）

| 演示 | 命令 | 材料 | 策略 | 结果 | 合计 delay/power/area/min_snr |
|---|---|---|---|---|---|
| demo-causal | `python eda_cli.py --desc examples/causal_chain_demo.json --pdk pdk/silicon_cim_v1.json --strategy min_delay` | silicon_cim_28nm_v1 | min_delay | OK, 6/6 映射 | 4.1ns / 23.9mW / 440um2 / 45.0dB |
| demo-optical | `python eda_cli.py --desc examples/causal_chain_demo.json --pdk pdk/optical_mzi_photonics_v1.json --strategy min_power` | optical_mzi_photonics_v1 | min_power | OK, 6/6 映射 | 4.2ns / 60.0mW / 1670um2 / 27.0dB |
| demo-full | `python eda_cli.py --desc examples/full_pipeline_demo.json --pdk pdk/silicon_cim_v1.json --strategy min_power` | silicon_cim_28nm_v1 | min_power | OK, 6/6 映射 | 3.8ns / 30.4mW / 570um2 / 45.0dB |

关键观察：
- 3 条链路全部 0 未映射，EDA 前端（解析→校验→映射→导出）自洽可跑。
- silicon 与 optical 对同一设计产出可对比的帕累托数据，证明"菜单级多材料"成立。
- optical 所有数值来自占位 PDK，**不代表光子物理可实现**。

### 1.2 RTL 仿真（待补跑）

`make sim` 在 Windows PowerShell 下无 make，需改用等价命令：
```
iverilog -g2012 -o g1_sim rtl/G1_Top_Integrated.sv rtl/ra_bus_arbiter.sv rtl/spl_pim_sequencer.sv rtl/spl_pim_cell.sv rtl/spl_pim_compute_array.sv rtl/spl_cim_causal_unit.sv rtl/ext_mem_controller.sv rtl/materica_compliance_unit.sv rtl/tb_G1_Integrated.sv
vvp g1_sim
```
状态：**未实跑**（用户本轮跳过，留待阶段 5 汇合时统一验证）。

## 2. 与 README 声称的对账

| 声称 | 实测 | 结论 |
|---|---|---|
| 阵列 4×4（README） | 顶层 `G1_Top_Integrated.sv` 已演进为 **v6/Phase B：PIM_ROWS=64, PIM_COLS=64（4096 cell）** | 文档严重滞后（4×4 → 64×64） |
| "10 tests / 0 errors" | testbench 实际含 **8 个 Test**（README 声称 10） | 文档夸大 |
| 材料兼容"多材料" | 结构容量无限，但 CLI 单次单选 1 种材料；单片混装无 per-op 分派 | "菜单级多材料"为真，"单片混装"为 overclaim |
| EDA→RTL 闭环 | 生成的 `spl_config_pkg.sv` 无任何 RTL import；`tb_stimulus` 全映射 cell(0,0)+MUL；`syn_tcl` 写死 6 文件清单 | 三处缝合线，均为断链 |

## 3. 阶段 0 结论

- EDA 前端（阶段 0 目标）**真实可用**：3 演示全 PASS。
- 工具链瓶颈不在前端，在 **EDA→RTL 三处断链**（阶段 1 目标）。
- 顶层 RTL 已演进至 4096 cell（v6/Phase B），远超文档描述，阶段 5 汇合时须以 64×64 参数化为准。
