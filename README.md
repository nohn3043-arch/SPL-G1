<p align="center">
  <img src="https://img.shields.io/badge/trusted--compute-unit-D4AF37?style=flat-square" alt="trusted-compute-unit">
  <img src="https://img.shields.io/badge/causal-audit-D4AF37?style=flat-square" alt="causal-audit">
  <img src="https://img.shields.io/badge/pim-array-D4AF37?style=flat-square" alt="pim-array">
  <img src="https://img.shields.io/badge/fp16-IEEE754-D4AF37?style=flat-square" alt="fp16">
  <img src="https://img.shields.io/badge/splcc-v0.1-D4AF37?style=flat-square" alt="splcc">
  <img src="https://img.shields.io/badge/phase-a--complete-D4AF37?style=flat-square" alt="phase-a-complete">
</p>

<blockquote align="center">
  <em>硬件因果审计可信计算单元（TCU）· 第二视角逻辑引擎</em>
</blockquote>

<div style="max-width:880px;margin:0 auto;padding:0 16px">

## ✦ 关于

<p style="font-size:15px;line-height:1.8;color:#2C2C2C">
SPL-G1 是<strong>硬件因果审计可信计算单元（TCU）</strong>——它不是通用 CPU/GPU/NPU，而是面向安全场景的专用原语，提供<em>可证明的硬件级因果审计</em>能力。基于 2D PIM（存内计算）阵列与 RA-BUS 统一寻址总线，兼具计算能力（SCALAR / VECTOR / MATRIX 三模）与硬件级因果约束校验、身份锚定（256 位）及不可逆 SBC 熔丝机制。每一步运算都产生可审计的 P→Q 因果对；任何违规都将被永久锁定。
</p>

<p style="font-size:15px;line-height:1.8;color:#2C2C2C">
<strong>Phase A——TCU 核心能力闭环已全部完成。</strong>能力里程碑 A1 控制流、A2 真 FP16、A3 <code>splcc</code> 编译器、A4 数据通道、A6 SBC 熔丝均已交付并经 RTL 仿真验证——集成测试平台（<code>tb_G1_Integrated.sv</code>，v3）完整通过 Phase-A 套件，<strong>0 错误</strong>（Icarus Verilog）。
</p>

</div>

<p align="center">— ✦ —</p>

## ✦ 定位：SPL-G1 是什么（与不是什么）

<div style="max-width:880px;margin:0 auto;padding:0 16px">

<table>
<tr><th>✅ 是</th><th>❌ 不是</th></tr>
<tr>
<td>硬件因果审计可信计算单元（TCU）</td>
<td>运行 Linux / x86 应用的桌面 CPU</td>
</tr>
<tr>
<td>具备全生命周期 P→Q 溯源的可验证计算原语</td>
<td>拥有数千核与 CUDA 生态的 GPU 显卡</td>
</tr>
<tr>
<td>三模 PIM 阵列（SCALAR / VECTOR / MATRIX）且每次运算均带审计</td>
<td>面向 LLM 推理的数据中心级 NPU 加速器</td>
</tr>
<tr>
<td>用于合规计算、安全关键审计、证明负载的嵌入式安全根</td>
<td>任何主流微处理器的替代品</td>
</tr>
</table>

</div>

<p align="center">— ✦ —</p>

## ✦ 快速开始

```bash
# 主源：GitHub
git clone https://github.com/nohn3043-arch/SPL-G1.git
# 镜像：Gitee（本仓库）
# git clone https://gitee.com/nohn-ecosystem/SPL-G1-General-purpose-processor.git
cd SPL-G1

# 核心 EDA 工具链——纯 Python ≥3.8，仅标准库
make demo-causal

# EDA → RTL 流水线：因果设计 → PDK 映射 → Verilog 配置
python eda_cli.py --desc examples/causal_chain_demo.json \
  --pdk pdk/silicon_cim_v1.json --strategy min_delay \
  --output outputs/netlist.json --rtl --rtl-dir outputs/rtlgen/

# RTL 仿真（需 Icarus Verilog 12.0+）
make sim          # 编译 + 运行：Phase-A 全套件，0 错误
make wave         # GTKWave 打开波形

# 将 C 子集程序编译为 SPL-G1 微码并验证语义
python splcc.py tests/loop_sub.c --verify
```

<p align="center">— ✦ —</p>

## ✦ 核心内容

<div style="max-width:880px;margin:0 auto;padding:0 16px">

- **硬件因果审计流水线**——每个计算步骤都携带可观测的 P→Q 因果痕迹；审计失败 → SBC 熔丝熔断 → 输出永久归零（Materica #4）。
- **三模 PIM 计算阵列**——4×4 存内计算网格（Cell v2：64 位本地存储 + 32 操作数 ALU），SCALAR / VECTOR / MATRIX 三种执行模式，8 位相邻互连，逐列 vec_sum，全阵列 mat_total 归约。
- **真 FP16（IEEE 754 半精度）**——符号 / 5 位指数 / 10 位尾数，次正规数 / NaN / ±Inf，`roundTiesToEven`；真实 `FP16_ADD / SUB / MUL / CMP / MAC` 语义（A2）。
- **因果约束（v2）**——`spl_cim_causal_unit` v2 硬约束校验：`constraint_pass = (constraint_bits == 64'hFFFF_FFFF_FFFF_FFFF)` + 56 位 `dep_mask` 依赖校验与级联失效。透传（桥接）模式下 constraint_bits 全 1 → 恒通过（A5）。
- **Sequencer v4**——参数化 256 项程序存储器，JMP / JZ / JNZ / CALL / RET / HALT 控制流指令，8 级返回栈，越界保护；RA-BUS READ 事务状态（v5 注解）供数据通道使用（A4）。
- **RA-BUS 仲裁器 v1**——4 目标地址解码总线（PIM / Audit / Identity / External），READ / WRITE / EXECUTE / CONFIG 事务类型。
- **身份锚 v1**——256 位硬件身份校验，64 周期逐位握手。
- **SBC 熔丝**——审计失败 → `fuse_blown` 锁存 → 输出强制归零；仅硬件复位可恢复（A6）。
- **EDA 工具链（纯 Python，仅标准库）**——`eda_cli.py` 驱动 parse → map → build → export → RTL 生成（`eda_parser.py` / `eda_mapper.py` / `eda_exporter.py` / `eda_rtlgen.py` / `EDA_fixed.py`）。
- **splcc——C 子集编译器 v0.1**——将受限 C 方言（int 变量、`for` / `while` / `if-else`、算术、比较）编译为 SPL-G1 微码 CONFIG 字，含 `--verify` 解释器模式（A3）。
- **RTL（SystemVerilog / Verilog）**——集成顶层 `G1_Top_Integrated.sv`（v3，Phase A）与 `G1_Commercial_Top.sv`；核心单元 `spl_pim_cell.sv`（v2，32 操作数 + FP16）、`spl_pim_compute_array.sv`（v2.1）、`spl_pim_sequencer.sv`（v4 控制流 / v5 总线回读）、`spl_cim_causal_unit.sv`（v2）、`ra_bus_arbiter.sv`、`ext_mem_controller.sv`、`materica_compliance_unit.sv`（v2）；扩展单元 `spl_tile.sv`、`spl_multi_tile_array.sv`、`spl_mesh_router.sv`、`spl_pim_reduce_tree.sv`；主机接口 `pcie_cxl_host_if.sv`，遗留 `g1_compute_core.sv` / `G1_Top_Interface.v`；测试平台 `tb_G1_Integrated.sv`（v3）、`tb_cell_v2.sv`、`tb_pim_compute_array.sv`、`tb_materica_compliance.sv`、`tb_G1_Top.sv`。
- **PDK 包**——`silicon_cim_v1.json`（28nm CIM）与 `optical_mzi_photonics_v1.json`（光子）。

</div>

<p align="center">— ✦ —</p>

## ✦ Make 目标

<div style="max-width:880px;margin:0 auto;padding:0 16px">

| `make` 目标 | 作用 |
|---|---|
| `make demo-causal` | 硅基 CIM PDK 因果链演示 |
| `make demo-audit` | 认知审计演示（低功耗优化） |
| `make demo-optical` | 光子 PDK 演示 |
| `make demo-full` | 完整流水线（COMPUTE 算子 + `params` 消耗） |
| `make demo-hetero` | 单片异质混合材料演示 |
| `make build DESC=<json>` | 编译自定义因果设计 |
| `make sim` / `make wave` | RTL 仿真 / 打开波形 |
| `make rtlgen` / `make rtlgen-apply` | EDA → RTL 包生成（应用补丁到 RTL） |
| `make pdk-report` / `make multi-pdk` | 材料覆盖矩阵 / 多 PDK 批量对比 |
| `make splcc-bridge` | 运行 `splcc_bridge.py tests/loop_sub.c --verify --emit outputs` |
| `make clean` | 清理构建产物与 `outputs/*.json` |

> RTL 仿真需要 **Icarus Verilog**（`iverilog` / `vvp`），可选 **GTKWave** 查看 `.vcd` 波形。

</div>

<p align="center">— ✦ —</p>

## ✦ 项目结构

```
SPL-G1/
├── eda_cli.py / eda_parser.py / eda_mapper.py / eda_exporter.py /
│   eda_rtlgen.py / EDA_fixed.py / eda_dataflow.py / eda_pdk_report.py
│                                   # EDA 工具链（纯 Python）
├── splcc.py / splcc_bridge.py      # C 子集 → SPL-G1 微码编译器（v0.1）
├── Makefile                        # demo / build / sim / splcc 目标
├── rtl/
│   ├── G1_Top_Integrated.sv        # 集成顶层 v3（RA-BUS + PIM + Audit + Anchor + Fuse）
│   ├── G1_Commercial_Top.sv        # 商用顶层（可扩展配置变体）
│   ├── ra_bus_arbiter.sv           # RA-BUS 4 目标仲裁器 + 地址解码
│   ├── spl_pim_cell.sv             # PIM Cell v2：64 位存储 + 32 操作数 ALU + 邻接 + FP16
│   ├── spl_pim_compute_array.sv    # PIM 阵列 v2.1：4×4，三模，pim_flag 输出
│   ├── spl_pim_sequencer.sv        # Sequencer v4：256 项程序存储器 + 控制流（+ v5 READ 状态）
│   ├── spl_cim_causal_unit.sv      # 因果审计单元 v2：约束校验 + 级联
│   ├── ext_mem_controller.sv       # 外部存储控制器（AXI4，RA-BUS 目标 3）
│   ├── materica_compliance_unit.sv # Materica 4 门硬件合规检查器（v2）
│   ├── spl_tile.sv · spl_multi_tile_array.sv · spl_mesh_router.sv · spl_pim_reduce_tree.sv  # 扩展单元
│   ├── pcie_cxl_host_if.sv         # PCIe Gen5 / CXL 2.0 主机接口
│   ├── g1_compute_core.sv · G1_Top_Interface.v   # 遗留核心 / 接口
│   ├── tb_G1_Integrated.sv         # 集成测试平台 v3（Phase-A 全套件，0 错误）
│   ├── tb_cell_v2.sv               # Cell v2 32 操作数覆盖测试
│   ├── tb_pim_compute_array.sv     # PIM 阵列独立测试
│   ├── tb_materica_compliance.sv   # Materica 合规单元测试
│   └── tb_G1_Top.sv                # 遗留顶层测试
├── pdk/                            # silicon_cim_v1.json, optical_mzi_photonics_v1.json
├── examples/                       # 因果 / 认知审计 / 完整流水线 / 异质演示
├── tests/                          # loop_sub.c（splcc 测试源）
├── outputs/                        # 生成的网表 / VCD 波形 / RTL 产物
├── docs/                           # ra_bus_protocol.md, BASELINE.md, EDA_ITERATION_DONE.md, history/, SPL-EDA 说明书.pdf, SPL-G1 Alignment Matrix.pdf
├── SPL-Core.json                   # ISA 定义（v1.0.0-Commercial：SPL-TCU-G1）
├── State_Anchor.pdl                # 256 位硬件身份锚协议
├── Materica-specification          # 4 项物质因果映射规范
├── IMPROVEMENT_PLAN.md             # 当前路线图（v5.0，TCU 定位，Phase A 完成）
└── README.md
```

<p align="center">— ✦ —</p>

## ✦ 生态

SPL-G1 是 NOHN AI 生态的一员——围绕第二视角因果审计与确定性执行构建的项目家族：

| 项目 | 仓库 | 定位 |
|---|---|---|
| **Second-Perspective (GCAE)** | [nohn3043-arch/second-perspective](https://github.com/nohn3043-arch/second-perspective) | 全局认知审计引擎——五算子因果审计内核（IMDA 95/100） |
| **NOMOS** | [nohn3043-arch/second-perspective](https://github.com/nohn3043-arch/second-perspective)（`Intelligent-Decision-Hub--Nomos` 分支） | 可审计确定性决策中心（IMDA 95/100） |
| **SPL-G1** | [nohn3043-arch/SPL-G1](https://github.com/nohn3043-arch/SPL-G1) | 硬件因果审计可信计算单元（TCU） |
| **SPL-Virtual-World-Base** | [nohn3043-arch/Second-Reality](https://github.com/nohn3043-arch/Second-Reality) | 虚拟世界与元宇宙基础设施（宪法 / 法律 / 桥梁） |
| **Story-Engine** | [nohn3043-arch/story-engine](https://github.com/nohn3043-arch/story-engine) | 长篇叙事一致性引擎 |
| **Antares** | [nohn3043-arch/Antares](https://github.com/nohn3043-arch/Antares) | GFSIP v1.0——带因果审计的联邦稳定互操作协议 |
| **Anthropomorphic-Agent-Engine** | [nohn3043-arch/Anthropomorphic-Agent-Engine](https://github.com/nohn3043-arch/Anthropomorphic-Agent-Engine) | 确定性拟人心理引擎（SPL Pure Core V8.0） |
| **PAGES** | [nohn3043-arch/pages](https://github.com/nohn3043-arch/pages) | NOHN AI 生态官方落地页 |

<p align="center">— ✦ —</p>

## ✦ 许可与授权

本仓库**非开源**，采用双轨模式：个人非商业研究免费；政府 / 企业需付费商业授权。详见 [LICENSE](./LICENSE)。申请专利（PCT）。

- **个人研究者**可依 [LICENSE](./LICENSE) 免费用于非商业研究，但不得用于任何商业用途。
- **政府 / 企业用户**须事先取得书面授权。
- **申请授权**：国际 / 全球 — [ai@nohnlins.com](mailto:ai@nohnlins.com) · 中国 — [lin@secondai.top](mailto:lin@secondai.top)

<p align="center">
  <a href="https://github.com/nohn3043-arch">GitHub</a>
  &nbsp;·&nbsp;
  <a href="https://www.nohnlins.com/">nohnlins.com</a>
  &nbsp;·&nbsp;
  <a href="mailto:ai@nohnlins.com">ai@nohnlins.com</a>
</p>
<p align="center"><sub>NOHN AI · SPL-G1 · 可信计算单元</sub></p>
