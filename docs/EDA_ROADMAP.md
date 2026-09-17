# SPL-EDA 持续迭代路线图（EDA_ROADMAP）

> 文档版本：v1.0 · 制定日期：2026-09-17
> 适用对象：SPL-G1 仓库内 EDA 工具链（`eda_cli.py` / `eda_*.py` / `EDA_fixed.py` / `splcc*.py`）
> 上游依据：`IMPROVEMENT_PLAN.md` v5.x、`docs/BASELINE.md`（阶段 0）、`docs/EDA_ITERATION_DONE.md`（阶段 0–5）
> 决策权：NOHN-AI · 许可：SPL-G1 双轨

---

## 1. 定位与边界

SPL-EDA 是**因果描述 → PDK 映射 → 网表 / RTL 工件的编译器前端**，纯 Python（≥3.8）且仅依赖标准库。

| ✅ 在范围内 | ❌ 不在范围内（永久） |
|---|---|
| 因果描述语言的解析与校验 | 布局布线（P&R） |
| 因果算子 → PIM cell 的映射与寻优 | DRC / LVS / 寄生提取 |
| 多材料 / 多 PDK 覆盖与帕累托对比 | SPICE 级晶体管电路仿真 |
| 网表导出、RTL 工件生成、综合脚本生成 | 流片（tapeout）相关流程 |
| C 子集（splcc）→ 微码的并轨验证 | 通用 HLS / 通用综合器替代 |

> 边界来源：`IMPROVEMENT_PLAN.md` §7「约束（保持不变）」——**两年内不流片，SPL-G1 只做到 M4 综合评估报告**。

---

## 2. 基线快照（v1.1）

| 项 | 状态 |
|---|---|
| EDA 工具链版本 | **v1.1**（2026-08-25，提交 `d65c01a feat(eda-v1.1): complete 5 gaps`） |
| 链路 | `parse → map → export → rtlgen`，`--multi-pdk` 帕累托、`--rows/--cols` 参数化、`splcc_bridge` 汇合 |
| 因果算子 | `NS / IAP / LCH / CCS / STATE`（5 类，无参数化 / 分支 / 循环 / 时序原语） |
| 映射策略 | `first_fit / min_delay / min_power / min_area` |
| RTL 工件 | `spl_config_pkg.sv`、`tb_eda_stimulus.sv`、`syn_tcl.tcl`、SVA 断言文本 |
| PDK 工艺库 | `silicon_cim_v1`（3 变体）、`optical_mzi_photonics_v1`（3 变体）、`rram_crossbar_v1`（3 变体） |
| 示例设计 | 5 个（含 `industrial_audit_pipeline.json`：32 算子 / 16×16 / delay 22.7ns） |
| Make 目标 | 17 个（`demo-* / rtlgen* / pdk-report / multi-pdk / splcc-bridge / sim / wave / build / clean`） |
| 演示基线 | `demo-causal / demo-optical / demo-full` 全 PASS，0 未映射 |

**已自陈的遗留真空**（见 `docs/EDA_ITERATION_DONE.md` §遗留真空，本路线图的主要输入）：
① micro-op 语义为占位；② PDK 数值为文献校准占位值；③ optical PDK 算子覆盖不全；④ Windows 无 `make` 导致回归未实跑；⑤ cell 分配器未做物理邻近优化。

---

## 3. 持续迭代五轴

### 轴 A — 前端表达力（`eda_parser.py` / `EDA_fixed.py`）

| ID | 迭代项 | 验收证据 |
|---|---|---|
| E-A1 | 描述语言 v2：新增 `cond`（条件分支）/ `loop`（定次循环）/ `param`（参数化算子）原语 | 新增 example 通过 parse + map + rtlgen 全链 |
| E-A2 | 时序原语：算子级 `latency` / `clock_domain` 标注 | 生成的 `syn_tcl` 含 `create_clock` 等约束 |
| E-A3 | 类型标注：位宽 / 定点 / FP16 类型系统 | 类型冲突时 `parse` 明确报错（非静默降级） |
| E-A4 | 描述语言正式化：JSON Schema + `schema_version` 字段，替代当前 `--print-format` 文本说明 | Schema 文件入库并可被校验器引用 |

### 轴 B — 后端落地能力（`eda_exporter.py` / `eda_rtlgen.py` / `eda_backend.py`）

| ID | 迭代项 | 验收证据 |
|---|---|---|
| E-B1 | **netlist → 结构化 RTL 生成**（当前仅产出参数包，不产结构） | 生成模块可被 `iverilog -g2012` 编译通过 |
| E-B2 | SDC 时序约束生成（当前 TCL 无 SDC） | 产出 `.sdc` 并随综合流程被读取 |
| E-B3 | 功耗估算模型（当前为 PDK 静态值求和） | 与 Yosys + PDK 估算偏差 < 30% |
| E-B4 | 面积模型升级：cell 面积求和 → 含互连开销估算 | 与综合实测面积同量级（偏差 < 50%） |
| E-B5 | micro-op 语义真实化：消除 `NS→ADD` / `IAP→CMP_EQ` 占位，接入 `eda_backend.OP_SEQUENCES` 并**对齐 NOMOS 约束规则** | 6/6 算子微操作序列与 RTL 行为一致（仿真佐证） |

### 轴 C — 验证闭环（新增 `eda_regress.py` 等）

| ID | 迭代项 | 验收证据 |
|---|---|---|
| E-C1 | **SVA 实跑**：当前只生成断言文本、从未执行 | 断言在仿真中真实触发（至少 1 条负向用例被捕获） |
| E-C2 | **Yosys 综合实跑**：当前只生成 TCL、未执行 | 产出 M4 综合评估报告（面积 / 最高频率） |
| E-C3 | 回归套件：`example × PDK × strategy` 组合矩阵 | PASS/FAIL 矩阵落盘，成功率 100% |
| E-C4 | 覆盖率统计接入 | 覆盖率报告随回归产出 |
| E-C5 | **跨平台回归**：Windows 无 `make` 的硬约束下提供纯 Python 驱动（**v1.1.1 已落地**） | `python eda_regress.py` 在 Windows / Linux 双端一致通过 |

### 轴 D — 工艺库与多材料（`pdk/` / `eda_pdk_report.py` / `eda_mapper.py`）

| ID | 迭代项 | 验收证据 |
|---|---|---|
| E-D1 | PDK Schema 版本化 + 独立校验器 `eda_pdk_check.py` | 缺字段 / 越界数值被拒绝 |
| E-D2 | 真实 PDK 替换路径：占位值 → 晶圆厂实测值的字段映射表 | 映射表入库，替换仅需换 JSON |
| E-D3 | 混装跨材料接口转换**成本模型**（当前只报边界条数） | 边界预算计入 delay/power/area 总量 |
| E-D4 | 补全 optical PDK 缺失变体（`NS` / `LCH`） | 覆盖矩阵 3 材料 × 6 类 cell 全绿 |

### 轴 E — 工程化与文档（仓库级）

| ID | 迭代项 | 验收证据 |
|---|---|---|
| E-E1 | CI：GitHub Actions 跑 `eda_regress.py` + Icarus 仿真 | PR 门禁可拦截回归 |
| E-E2 | `CHANGELOG.md` 语义化变更记录 | 每个 release 有对应条目 |
| E-E3 | CLI 稳定化：统一错误码、`--schema` 导出、废弃项走 deprecation 周期 | CLI 契约文档入库 |
| E-E4 | 文档同步：每次 minor 重生成 `docs/SPL-EDA 说明书.pdf` | PDF 与代码版本号一致 |
| E-E5 | 测试夹具标准化 `tests/fixtures/`（**v1.1.1 已落地**） | 示例与夹具分离，回归可独立引证 |

---

## 4. 更新频率（Cadence）

### 4.1 版本语义（SemVer 适配）

| 位 | 含义 | 示例 |
|---|---|---|
| **MAJOR** | 描述语言 / CLI 契约**不兼容**变更 | 描述语言 v2 冻结 |
| **MINOR** | 向后兼容的**新能力** | 新增 SDC 生成 |
| **PATCH** | 缺陷修复、数值校准、文档同步 | PDK 数值更新 |

### 4.2 常规节奏

| 类型 | 频率 | 发布窗口 | 最小内容要求 |
|---|---|---|---|
| **PATCH** | **双周**（每 2 周，week 三） | 2026-09 起 | ≥1 条修复或文档同步；不引入新能力 |
| **MINOR** | **每季度**（Q4 / Q1 / Q2 / Q3 末） | 与 Phase 推进对齐 | ≥1 个轴完成一个 ID 并通过验收 |
| **MAJOR** | **每半年至一年** | 阶段冻结点 | 完成一个里程碑（M 系列）并冻结契约 |

> 节奏锚定 EDA v1.1 的实际交付间隔（v1.1 于 2026-08-25 完成）与 `IMPROVEMENT_PLAN.md` §7 的既有迭代习惯。

### 4.3 触发式插队（例外通道）

以下事件可**打破常规节奏**，立即发布 PATCH 或 MINOR：

1. **外部依赖到位**：晶圆厂实测 PDK 替换占位值（→ MINOR）
2. **工具链升级**：Icarus Verilog / Yosys 大版本变更导致产物不兼容（→ PATCH）
3. **验证暴露缺陷**：回归或 RTL 仿真发现 EDA 产物错误（→ PATCH，最高优先级）
4. **上游对齐**：`SPL-Core.json`（ISA）或 NOMOS 约束规则变更致 micro-op 语义需同步（→ MINOR）

### 4.4 发布硬门禁（DoD —— 六条全过方可发版）

1. **可执行**：全部 `make demo-*` 目标 exit 0，无未映射算子
2. **可复现**：同一 `desc + pdk + strategy` 两次运行产出一致（数值确定性）
3. **有硬验证**：本轮新增能力必须附 RTL 仿真 / Icarus / Yosys 证据或波形，**不接受"已生成文件"作为验证**
4. **不回归**：已有 17 个 Make 目标与历史演示保持 PASS
5. **文档同步**：`README.md` / `IMPROVEMENT_PLAN.md` / 本文件版本号三者一致
6. **变更留痕**：`CHANGELOG.md` 或 commit message 标注对应 gap / 轴 ID（如 `E-C2`）

---

## 5. 排期表

| 版本 | 类型 | 目标窗口 | 主题 | 对应轴 |
|---|---|---|---|---|
| **v1.1.x** | PATCH | 2026-09 → 2026-11（双周） | 稳定化：文档对齐、数值校准、Win 回归驱动 | E-E5 / E-C5 |
| **v1.2** | MINOR | **2026-Q4（2026-12）** | **验证闭环**：回归套件 + SVA 实跑 + CI | E-C1 / E-C3 / E-E1 |
| **v1.3** | MINOR | 2027-Q1（2027-03） | **前端表达力**：描述语言 v2（cond / loop / param） | E-A1 / E-A4 |
| **v1.4** | MINOR | 2027-Q2（2027-06） | **后端落地**：结构化 RTL 生成 + SDC + micro-op 真实化 | E-B1 / E-B2 / E-B5 |
| **v1.5** | MINOR | 2027-Q3（2027-09） | **物理量模型**：功耗 / 面积估算 + PDK 真实化 | E-B3 / E-B4 / E-D2 |
| **v2.0** | MAJOR | **2027-Q4（2027-12）** | **契约冻结 + M4 综合评估报告** | 全轴收敛 |

**里程碑映射**（沿用 `IMPROVEMENT_PLAN.md` §6）：

| 里程碑 | 定义 | 本路线图对应 |
|---|---|---|
| M2: 首版编译器 | splcc 产出可跑微码 | ✅ 已达成（v0.1） |
| M3: Tile 扩展 | 16×16 阵列测试通过 | ✅ 已达成（`industrial_audit_pipeline`） |
| **M4: 综合结果** | **Yosys 面积 / 频率 / 功耗评估** | **v2.0 交付物（E-C2 + E-B3 + E-B4）** |

**外部约束**：两年内不流片（至 ~2028-08），v2.0 即为本路线图终点；后续规划另行制定。

---

### 5.1 v1.1.x 进展日志

| 版本 | 日期 | 交付 | 验证 |
|---|---|---|---|
| **v1.1.1** | 2026-09-17 | 新增 `eda_regress.py`（纯 Python 跨平台回归驱动，脱离 `make`）+ `tests/fixtures/min_chain.json`；建立 `KNOWN_FRAGILE` 已知脆弱用例清单机制 | 全量矩阵 **72 用例**：PASS 60 / KNOWN-FAIL 12（`heterogeneous_demo` 单片混装，预期）/ 门禁失败 0，`rc=0` |

> 已知脆弱项说明：`heterogeneous_demo` 使用 per-op `material` 单片混装，单 PDK 的 `eda_cli` 路径不支持（需 `make demo-hetero` / 多材料逻辑），故在单 PDK 回归下标记为 KNOWN-FAIL 并排除出门禁，符合 §3 的诚实标注约定。

## 6. 迭代工作方式

```
① 从本文件 §3 取一个 ID（如 E-C3）
② 在 IMPROVEMENT_PLAN.md 登记该 ID 的当期状态
③ 实施 + 硬验证（产生可复现证据，落盘到 outputs/ 或 tests/）
④ 过 §4.4 六条门禁
⑤ 更新 CHANGELOG / 版本号 / 本文件"状态"列
⑥ 归档证据：图表或波形入 outputs/，结论入 docs/
```

- **一次迭代只推进一个 ID**，不允许"顺手重构"混入（防止回归面不可界定）。
- **未过门禁不回滚版本号**：以 PATCH 递增重试，保留失败记录。
- **诚实标注**：任何未实跑、占位值、外部依赖项，必须在文档中显式标注（沿用 `EDA_ITERATION_DONE.md` 的"遗留真空"格式）。

---

## 7. 明确不迭代（防范围蔓延）

以下项在 v2.0 前**不进入本路线图**，如需立项须单独出方案并重新评审：

1. 物理布局布线（P&R）与拥塞分析
2. DRC / LVS / 寄生参数提取
3. SPICE / 器件级电路仿真
4. 通用 HLS（SystemC / C++ 抽象级综合）
5. 通用 CPU / GPU 编译后端
6. 流片（tapeout）与硅后验证流程

---

*Decision authority: NOHN-AI · Architecture: SPL-TCU-G1 · License: SPL-G1 dual-track.*
