# SPL-G1 TCU 改进计划 v4.0

> Version 4.0 — 2026-08-05
> 定位修正: Trusted Compute Unit (TCU)。Phase A 已过半(A1/A6 完成)。

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
| **C1** | 无编译器 | 编程 = 手写微码 hex | TCU 无法被外部工具编程 |
| **C2** | FP16 虚假 | 整数运算冒充 IEEE 754 | 浮点审计/计算不可信 |
| **C3** | 审计空转 | constraint_bits=全1, pass-through | "因果审计"是形式标签 |
| **C4** | 无外存/IO | RA-BUS target 3 = 存根,无传感器接口 | 数据进不来出不去 |
| **C5** | 规模太小 | 16 单元 × 64bit = 128 字节 | 装不下任何真实规则库 |
| **C6** | 无时序/面积/功耗 | 未跑综合(Yosys/DC) | 不知道能不能流片 |

---

## 3. Phase A — TCU 核心能力闭环(当前阶段)

### A1. 控制流 ✅ 完成
spl_pim_sequencer v4: 256-entry 程序存储器, JMP/JZ/JNZ/CALL/RET/HALT, 8-deep return stack, OOB 保护。

### A6. SBC 熔断 ✅ 完成
G1_Top v3: fuse_blown 输出, audit_fb_pass==0 → 永久锁定 → ra_rdata 强制清零, 仅 rst_n 恢复。

### A2. 真 FP16(BF16) — 优先级最高
**目标**: 实现 IEEE 754 half-precision 算术。
- 符号位 / 指数(5-bit) / 尾数(10-bit) / 舍入模式(roundTiesToEven)
- 特殊值: NaN / ±Inf / subnormal
- 测试向量: subnormal × Inf → NaN, 0 × Inf → NaN, etc.

### A3. splcc 编译器 v0.1
**目标**: C 子集 → SPL-G1 微码。最低交付: `for` 循环 + `if/else` + 数组 → 跑通仿真。
- 前端: 词法+语法 → 三地址码 IR
- 后端: 寄存器分配(local_store 映射) + 微码调度 + audit tag 注入

### A4. 数据通道
- RA-BUS READ 事务实现 + 回读验证
- 外部存储接口(RA-BUS target 3)从存根升级为内存映射
- 传感器对账接口(基准数据注入)

### A5. 因果约束规则 v1
**目标**: 关闭 pass-through,真查违规。
- 最小规则集(6-10 条): 如"禁止 EVOLVE 后未经 AUDIT 直接 ANCHOR"
- 加载到 constraint_bits → audit 对违规正确 reject → fuse_blown 测试可通过

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
