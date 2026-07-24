# RA-BUS 总线协议 v1.0

## 概述

RA-BUS 是 SPL-G1 处理器内部唯一的互连骨干，将所有子模块（PIM 计算阵列、因果审计阵列、身份锚定、外挂扩展存储）统一连接在单一地址平面上。

## 物理信号

| 信号 | 位宽 | 方向 | 描述 |
|------|------|------|------|
| `ra_valid` | 1 | Host→Bus | 总线事务有效 |
| `ra_cmd` | 2 | Host→Bus | 00=READ 01=WRITE 10=EXECUTE 11=CONFIG |
| `ra_addr` | 32 | Host→Bus | [31:30]=目标, [29:28]=保留, [27:0]=目标内偏移 |
| `ra_wdata` | 64 | Host→Bus | 写数据 / 执行操作数 |
| `ra_rdata` | 64 | Bus→Host | 读数据 |
| `ra_ready` | 1 | Bus→Host | 目标模块就绪（握手完成） |
| `ra_resp` | 2 | Bus→Host | 00=OK 01=ERROR 10=AUDIT_HALT 11=RETRY |
| `ra_tag` | 8 | Host→Bus | 因果标签 ID（v1.1 预留） |

## 地址空间映射

```
0x0_0000000 ~ 0x0_FFFFFFF  →  PIM Compute Array (256 MiB)
  0x0_0000000 ~ 0x0_00000FF    PIM 微指令表 (16 条 × 8 字节)
  0x0_0000100 ~ 0x0_00001FF    PIM 阵列数据窗口 (ROWS×COLS×8B)
  0x0_0000200 ~ 0x0_FFFFFFF    保留

0x1_0000000 ~ 0x1_FFFFFFF  →  Causal Audit Array
  0x1_0000000 ~ 0x1_0000003    审计单元 0..3 状态读回
  0x1_0000100 ~ 0x1_FFFFFFF    保留

0x2_0000000 ~ 0x2_FFFFFFF  →  Identity Anchor
  0x2_0000000                  Hash nibble 提交口
  0x2_0000100 ~ 0x2_FFFFFFF    保留

0x3_0000000 ~ 0x3_FFFFFFF  →  外挂扩展存储（预留）
```

## 事务时序

### READ 事务
```
  clk      : _/‾\_/‾\_/‾\_/‾\_/‾\_
  ra_valid : ___/‾‾‾‾‾‾‾‾‾\__________
  ra_cmd   : ___X__00___X_____________
  ra_addr  : ___X target X_____________
  ra_ready : __________/‾‾‾‾\__________
  ra_rdata : __________X data X_________
```
- Host 置 ra_valid=1 + ra_cmd=READ + ra_addr
- 目标模块在下个周期置 ra_ready=1 + ra_rdata 有效
- Host 在 ra_ready 上升沿采样 ra_rdata

### WRITE / EXECUTE / CONFIG 事务
```
  clk      : _/‾\_/‾\_/‾\_/‾\_/‾\_
  ra_valid : ___/‾‾‾‾‾‾‾‾‾\__________
  ra_cmd   : ___X WR/EX/CF X_________
  ra_addr  : ___X target X_____________
  ra_wdata : ___X  data   X_____________
  ra_ready : __________/‾‾‾‾\__________
```
- 目标在 ra_valid 有效周期锁存 ra_cmd + ra_addr + ra_wdata
- 下周期返回 ra_ready 确认

### EXECUTE 特殊语义
- PIM 阵列收到 EXECUTE 时，pim_store=1，阵列按当前 exec_mode 执行
- 执行完成后 pim_ready=1，pim_rdata 包含 SCALAR 结果或 0

## CONFIG 事务 (PIM 微指令表编程)
- 目标地址 0x0_00000xx（xx = 表项 0~15）
- ra_wdata[1:0]   = exec_mode (SCALAR/VECTOR/MATRIX)
- ra_wdata[15:8]  = micro-op (ADD/SUB/MUL/MAC/CMP/SHIFT/XOR/NOP)
- ra_wdata[63:16] = 保留

## 错误处理
- `ERROR` (01): 目标不存在或访问越界
- `AUDIT_HALT` (10): 因果审计单元检测到违规，流水线暂停
- `RETRY` (11): 目标忙，需重试（暂未实现）
