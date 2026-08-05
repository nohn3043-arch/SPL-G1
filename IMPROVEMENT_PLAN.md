# SPL-G1 TCU 改进计划 v5.0

> Version 5.0 — 2026-08-05
> 定位修正: Trusted Compute Unit (TCU)。**Phase A 全部完成(A1-A6)。**

---

## 0. 定位修正

| | 旧定位(已废除) | 新定位(当前) |
|---|-------------|------------|
| 产品类别 | "CPU+GPU+NPU 三合一通用处理器" | **硬件因果可审计可信计算单元 (TCU)** |
| 核心价值 | 取代传统处理器 | **为安全关键系统提供可证明的全生命周期因果审计** |
| 典型载体 | 独立芯片替换 CPU | **嵌入 SoC 的审计根 / 安全模块 / 合规芯片** |
| 对标物 | Intel/AMD/NVIDIA | **TPM + 可验证计算的硬件实现** |

---

## 1. 当前实现状态

| 模块 | 版本 | 状态 |
|------|------|------|
| PIM Cell | v2 | ✅ 64-bit store + 32-op ALU + 8-bit neighbour |
| PIM Array | v2.1 | ✅ 4×4 grid, SCALAR/VECTOR/MATRIX, pim_flag |
| Sequencer | v4 | ✅ 256-entry prog mem + JMP/JZ/JNZ/CALL/RET/HALT |
| RA-BUS Arbiter | v1 | ✅ 4-target, READ/WRITE/EXECUTE/CONFIG |
| Audit Unit | v2 | ✅ constraint_pass + dep_mask cascade |
| G1_Top | v3 | ✅ SBC fuse_blown (Materica #4) |
| Identity Anchor | v1 | ✅ 256-bit, 64-cycle nibble handshake |
| EDA Toolchain | v1 | ✅ parse→map→export→rtlgen |
| **仿真** | — | ✅ **0 errors, 7/7 tests PASS** (Icarus Verilog) |

---

## 2. 剩余差距(按验收优先级)

| # | 差距 | 现状 | 影响 |
|---|------|------|------|
| **C1** | ~~无编译器~~ | ✅ splcc.py v0.1 已交付 | C→微码可行,待扩展 |
| **C2** | ~~FP16 虚假~~ | ✅ IEEE 754 已实现 | 浮点可信 |
| **C3** | ~~审计空转~~ | ✅ constraint mask 可编程 | 违规→熔断闭环已验证 |
| **C4** | ~~无外存/IO~~ | ✅ READ 事务 + ext_mem_controller | 数据通道可用 |
| **C5** | 规模太小 | 16 单元 × 64bit = 128 字节 | 装不下真实规则库 |
| **C6** | 无时序/面积/功耗 | 未跑综合(Yosys/DC) | 不知道能不能流片 |

---

## 3. Phase A — TCU 核心能力闭环(当前阶段)

### A1. 控制流 ✅ 完成
spl_pim_sequencer v4: 256-entry 程序存储器, JMP/JZ/JNZ/CALL/RET/HALT, 8-deep return stack, OOB 保护。

### A6. SBC 熔断 ✅ 完成
G1_Top v3: fuse_blown 输出, audit_fb_pass==0 → 永久锁定 → ra_rdata 强制清零, 仅 rst_n 恢复。

### A2. 真 FP16 ✅ 完成
IEEE 754 half-precision (roundTiesToEven) 实现于 `spl_pim_cell.sv`:
- 符号/指数(5-bit)/尾数(10-bit)/subnormal/NaN/±Inf
- FP16_ADD/SUB/MUL/CMP/MAC 全部真实 IEEE 语义,替换整数 stubs

### A3. splcc 编译器 v0.1 ✅ 完成
`splcc.py` + `tests/loop_sub.c`:
- 词法/语法 → 三地址码 IR → SPL-G1 微码 CONFIG 输出
- 支持 int 变量 / for / while / if-else / 算术 / 比较
- `--verify` 解释器模式验证语义

### A4. 数据通道 ✅ 完成
- Sequencer v5: RA-BUS READ 事务(SEQ_READ 状态)
- ext_mem_controller 集成(RA-BUS target 3)
- 读回路径验证

### A5. 因果约束规则 v1 ✅ 完成
- `audit_constraint_mask`(64-bit CONFIG 可编程, audit target):
  - bit[0] 整数 ALU / bit[1] FP16 / bit[2] VECTOR / bit[3] MATRIX
  - 默认全 1(bridge 模式,向后兼容)
- `constraint_bits_latch` dispatch 时锁存,避免组合时序误判
- Test 9 闭环验证: 禁 FP16 → 执行 FP16_ADD → audit reject → fuse_blown=1
  → PIM 输出切断(9d)但审计/身份通道仍可读(9e/9f)

---

## 4. 应用路径: 安全审计节点

### 工业安全(你的需求)
```
SPL-G1 TCU = 流水线的"审计账本"
  每道工序 → P→Q 因果记录
    → audit 比对安全规范
      → 违规跳步 → fuse_blown → 闸机急停 + 不可篡改的违规记录
```

### 合规计算
```
云信任: "服务器有没有篡改 AI 推理结果?"
  → TCU 旁路审计: 每个推理步骤的 P→Q 标签公开可验证
```

### 供应链追溯
```
"这批零件是从哪里来的?"
  → State_Anchor + 全链路 P→Q 追踪 = 造假无法覆盖
```

---

## 5. 规模扩展阶梯

| 级别 | 规模 | 工作集 | 可跑什么 | 里程碑 |
|------|------|--------|---------|--------|
| L0 原型 | 4×4=16 单元 | 128 B | 演示级整数运算 | ✅ 当前 |
| L1 嵌入核 | 16×16=256 单元 | 4 KB | 真实单片机级程序(需 A3 编译器) | Phase B |
| L2 AI 加速 | 64×64=4096 单元 | 64 KB | 微型 MLP,传感器端分类 | Phase C |
| L3 存储级 | 262,144 单元 | 2 MB | 工业审计规则库 + 批次追溯 | 需流片 |

---

## 6. 里程碑

| 里程碑 | 定义 | 验证标准 |
|--------|------|---------|
| M1: TCU 可信闭合 | A2+A3+A4+A5 全部完成 | 仿真可跑审计循环, fuse 可闭环测试 |
| M2: 首版编译器 | splcc 产出可跑微码 | `for` 循环仿真通过 |
| M3: Tile 扩展 | 16×16 阵列 | 所有模式测试通过 |
| M4: 综合结果 | Yosys 面积/频率/功耗 | 评估可流片性 |

---

*Decision authority: NOHN-AI. License: SPL-G1 dual-track.*
*Architecture: SPL-TCU-G1 — Hardware Causal-Audit Trusted Compute Unit.*
