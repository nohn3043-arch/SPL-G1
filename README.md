<p align="center">
  <img src="https://img.shields.io/badge/SPL--G1-D4AF37?style=flat-square" alt="SPL-G1">  <img src="https://img.shields.io/badge/causal--audit-D4AF37?style=flat-square" alt="causal-audit">  <img src="https://img.shields.io/badge/fpga--ready-D4AF37?style=flat-square" alt="fpga-ready">
</p>

<blockquote align="center">
  <em>通用因果审计硬件流水线</em>
</blockquote>

<div style="max-width:880px;margin:0 auto;padding:0 16px">

## ✦ 关于

<p style="font-size:15px;line-height:1.8;color:#2C2C2C">SPL-G1 是<strong>因果审计硬件流水线</strong>：将第二视角因果审计引擎编码为可在 FPGA / ASIC 上确定性运行的流水线。它把"叙事剥离 → 内隐假设透视 → 脆弱性锁存 → 因果链同步 → 状态锚定"五个算子固化进硬件，使每一条因果链都可被独立验证、哈希链式记录、且不被篡改。</p>

<p style="font-size:15px;line-height:1.8;color:#2C2C2C">软件层仍是参考实现，硬件层是可综合的寄存器传输级（RTL）描述。两者对齐同一套确定性语义，因此软件结果可在硬件上复现。</p>

</div>

<p align="center">— ✦ —</p>

## ✦ 五算子流水线

| 阶段 | 算子 | 硬件单元 | 功能 |
|---|---|---|---|
| 1 | 叙事剥离 NS | `narrative_strip` | 去除修辞与模糊量词，输出结构化因果事件 |
| 2 | 内隐假设透视 IAP | `assumption_lens` | 提取未声明假设，标注特权与循环依赖 |
| 3 | 脆弱性锁存 LCH | `fragility_latch` | 计算每个假设的崩塌概率 ΔD，定位最弱变量 |
| 4 | 因果链同步 CCS | `causal_sync` | 逆反校验 + 反事实重放 + 黑洞检测 |
| 5 | 状态锚定 STATE | `state_anchor` | 责任锚定 + SHA-256 审计凭证上链 |

<p align="center">— ✦ —</p>

## ✦ 仓库结构

```
SPL-G1-general-purpose-processor/
├── rtl/                     # 可综合 RTL（Verilog/SystemVerilog）
│   ├── narrative_strip.v
│   ├── assumption_lens.v
│   ├── fragility_latch.v
│   ├── causal_sync.v
│   └── state_anchor.v
├── sim/                     # 仿真激励与黄金向量
├── sw/                      # 软件参考实现（Python）
├── docs/                    # 流水线规范与接口定义
├── constraints/             # 时序与物理约束
└── LICENSE
```

<p align="center">— ✦ —</p>

## ✦ 软件参考实现

```bash
cd sw
pip install -r requirements.txt
python run_pipeline.py --input decision.json   # 输出哈希链式审计轨迹
```

<p align="center">— ✦ —</p>

## ✦ 仿真

```bash
cd sim
# 使用 Icarus Verilog / Verilator
make sim        # 跑通全部黄金向量
```

<p align="center">— ✦ —</p>

## ✦ 确定性保证

- 所有中间表示采用规范化的字节序与定长字段。
- 哈希链使用 SHA-256，每个审计事件携带前一事件的根哈希。
- 软件与硬件共享同一组黄金向量，偏差即视为实现缺陷。

<p align="center">— ✦ —</p>

## ✦ 使用场景

- **高可信决策硬件**：金融、能源、军工等不容许"黑箱"的领域。
- **合规取证**：将因果审计轨迹直接固化进可信执行环境。
- **边缘审计**：在断网设备上本地完成可验证审计。

<p align="center">— ✦ —</p>

## ✦ 许可与授权

本仓库**非开源**。采用双轨模式：个人非商业研究免费；政府 / 企业需事先取得书面商业授权。详见 [LICENSE](./LICENSE)。

**授权咨询**：
- 国际 / 全球：ai@nohnlins.com
- 中国：lin@secondai.top

<p align="center">
  <a href="https://github.com/NOHN-AI">NOHN-AI</a>
  &nbsp;·&nbsp;
  <a href="https://www.nohnlins.com/">nohnlins.com</a>
  &nbsp;·&nbsp;
  <a href="mailto:ai@nohnlins.com">ai@nohnlins.com</a>
</p>
<p align="center"><sub>NOHN AI · SPL-G1</sub></p>
