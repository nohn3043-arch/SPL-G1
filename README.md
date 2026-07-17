

基于项目结构和原始README内容，我将为您创建一个全面且专业的README文档：

```markdown
# SPL-G1 通用处理器项目

## 目录

- [项目简介](#项目简介)
- [核心特性](#核心特性)
- [系统架构](#系统架构)
- [快速开始](#快速开始)
- [项目结构](#项目结构)
- [技术规格](#技术规格)
- [文档资源](#文档资源)
- [许可协议](#许可协议)
- [联系方式](#联系方式)

---

## 项目简介

SPL-G1（Second-Perspective Logic 通用核心）是一款基于**第二代视角逻辑**的实验性通用异构处理器架构。该项目实现了一个真正的4合1统一计算平台，集成了CPU标量处理、GPU并行渲染、NPU神经推理以及原生态状态存储功能。

### 设计理念

- **超低功耗架构**：通过在状态所在地执行计算，最大限度地减少数据移动
- **真正统一的通用计算基质**：标量逻辑、并行吞吐量、张量推理和持久状态共存于统一的执行模型
- **硬件级确定性可审计性**：通过RA-BUS（责任锚定总线）在硬件层面实现可追溯、锚定且因果一致的计算

### 技术创新

1. **因果拓扑架构**：计算逻辑由因果关系定义，而非硅基物理实现
2. **跨材料适应协议(CMAP)**：支持碳纳米管、光子晶体、自旋电子阵列和合成生物逻辑等多种物理载体
3. **状态锚定机制**：256位合成身份标识 + 64周期验证机制

---

## 核心特性

### 多范式统一计算

| 计算模式 | 功能描述 |
|---------|---------|
| CPU风格 | 指令获取与标量处理 |
| GPU级别 | SIMD并行渲染能力 |
| NPU优化 | 可信人工智能推理 |
| 原生状态存储 | 持久内存管理 |

### 因果审计流水线

```
ANCHOR → EVOLVE → AUDIT → STRIP
```

- **叙事剥离(NSM)**：从语义噪声中提取形式逻辑
- **隐式假设检测(IAP)**：硬件级(P→Q)前提验证
- **责任锚定**：可追溯的权重和逻辑决策点
- **漏洞对冲**：关键逻辑链的概率性坍缩检测

---

## 系统架构

### 指令集架构

SPL-Core定义了11个操作码，包括核心的COMPUTE指令，以及完整的因果处理流水线支持。

### 硬件实现

- **计算核心** (`g1_compute_core.sv`)：5种因果计算模式
- **因果检查单元** (`spl_cim_causal_unit.sv`)：8入口禁止矩阵
- **顶层接口** (`G1_Top_Interface.v`)：计算→审计流水线 + 64周期身份锚定
- **测试平台** (`tb_G1_Top.sv`)：4种通过/失败场景

### EDA工具链

```
EDA_fixed.py      # 核心：因果操作类型/CausalIR/参数消耗/PDK加载
eda_parser.py     # 因果描述JSON → CausalIR解析器
eda_mapper.py     # 技术映射器（带参数亲和力决胜）
eda_exporter.py   # 网表JSON + 报告输出（带参数警告）
eda_cli.py        # CLI入口点
```

---

## 快速开始

### 环境要求

- Python 3.8+
- 依赖项：`pip install -r requirements.txt`

### 基础使用

```bash
# 解析因果描述并生成网表
python eda_cli.py --desc examples/full_pipeline_demo.json --pdk pdk/silicon_cim_v1.json --strategy min_power --output outputs/netlist.json
```

### 可用策略

- `min_delay`：最小延迟优化
- `min_area`：最小面积优化  
- `min_power`：最小功耗优化

### PDK支持

- **硅基CIM 28nm工艺**：pdk/silicon_cim_v1.json
- **光学MZI光子学**：pdk/optical_mzi_photonics_v1.json（占位符）

---

## 项目结构

```
SPL-G1-General-purpose-processor/
├── EDA_fixed.py              # 核心EDA引擎 (v0.4.0)
├── eda_parser.py             # 因果描述解析器
├── eda_mapper.py             # PDK技术映射器
├── eda_exporter.py           # 网表和报告生成器
├── eda_cli.py                # 命令行接口
├── SPL-Core.json             # 指令集定义 (11个操作码)
├── State_Anchor.pdl          # 状态锚定协议规范
├── Materica-specification    # 跨材料因果映射规范
│
├── rtl/                      # 硬件描述 (SystemVerilog v0.2.0)
│   ├── g1_compute_core.sv    # 计算处理核心
│   ├── G1_Top_Interface.v    # 顶层接口
│   ├── spl_cim_causal_unit.sv # 因果审计单元
│   └── tb_G1_Top.sv          # 测试平台
│
├── pdk/                      # 工艺设计套件
│   ├── silicon_cim_v1.json   # 硅基CIM 28nm
│   └── optical_mzi_photonics_v1.json # 光学MZI
│
├── examples/                 # 因果描述示例
│   ├── causal_chain_demo.json        # 完整5操作码链演示
│   ├── cognitive_audit_demo.json     # 认知审计红线硬块用例
│   └── full_pipeline_demo.json       # 完整流水线演示
│
├── docs/                     # 规格文档
│   ├── SPL-EDA 说明书.pdf
│   └── SPL-G1 Alignment Matrix.pdf
│
└── outputs/                  # 生成的网表输出
```

---

## 技术规格

### 身份锚定

- **硬件标识符**：`0x8525d007_59a4ca22`
- **合成身份**：256位
- **验证周期**：64周期

### 因果操作类型

支持完整的因果操作链：
- ANCHOR：状态锚定
- EVOLVE：状态演化
- AUDIT：因果审计
- STRIP：叙事剥离
- COMPUTE：通用计算

### 跨材料适配

| 材料类型 | 支持状态 | 说明 |
|---------|---------|------|
| 碳纳米管(CNT) | 稳定 | 二进制状态稳定映射 |
| 光子晶体 | 实验性 | 光学计算载体 |
| 自旋电子阵列 | 规划中 | 磁自旋态计算 |
| 合成生物逻辑 | 探索中 | DNA/蛋白质计算 |

---

## 文档资源

### 规格文档

- [SPL-EDA说明书.pdf](docs/SPL-EDA%20%E8%AF%B4%E6%98%8E%E4%B9%A6.pdf) - SPL-EDA工具链详细说明
- [SPL-G1 Alignment Matrix.pdf](docs/SPL-G1%20Alignment%20Matrix.pdf) - 材料/编译器/芯片三层因果对齐证明

### 示例演示

1. **因果链演示** (`examples/causal_chain_demo.json`)
   - 完整5操作码链展示
   
2. **认知审计演示** (`examples/cognitive_audit_demo.json`)
   - 认知审计红线硬块使用案例
   
3. **完整流水线演示** (`examples/full_pipeline_demo.json`)
   - 端到端流水线执行（包含COMPUTE和参数消耗）

---

## 许可协议

### 许可证类型

| 用户类型 | 用途 | 许可证要求 |
|---------|------|-----------|
| 个人（自然人） | 非商业学术研究/学习/个人实验 | [免费个人研究许可证](./LICENSE) |
| 政府机构/公共机构/企业 | 任何用途（包括内部部署、产品开发、服务提供） | **需预先书面授权并付费** |

### 重要声明

- **个人研究者**可免费将本作品用于非商业研究，但不能用于任何商业目的，也不能向任何企业或政府组织提供服务。
- **政府/企业用户**在签署商业授权协议并支付约定费用之前，不得复制、部署、运行、集成或分发本作品。
- **技术展示用途**：本仓库是SPL-G1通用处理器的技术展示。

### 法律状态

- **专利状态**：所有相关技术已提交PCT国际专利申请
- **专利号**：PCT/CN2026/094913
- **警告**：本项目所有硬件实现代码、配置文件和协议文档均为专利申请中技术，仅供**学术参考**。任何形式的商业复制、硬件物理实现或专利规避设计均**严格禁止**。

---

## 联系方式

### 国际/全球
- 邮箱：[ai@nohnlins.com](mailto:ai@nohnlins.com)

### 中国地区
- 邮箱：[ai@tx.nohnlins.com](mailto:ai@tx.nohnlins.com)

---

## 版本信息

- **当前版本**：v0.2.0 (RTL), v0.4.0 (EDA)
- **项目阶段**：架构规格 + 功能性RTL流水线
- **关注重点**：因果审计流水线、计算核心集成、跨材料PDK

---

## 致谢

感谢您对可信计算的贡献。只有可信赖的计算才有未来。

---

**版权声明**：Copyright © 2026 上海林明峻华科技有限公司 和 NOHN AI TECHNOLOGY PTE. LTD. 版权所有。
```