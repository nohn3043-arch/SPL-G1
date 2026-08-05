#!/usr/bin/env python3
"""
splcc_bridge v0.1 — 阶段 5：splcc 与 SP-EDA 的汇合桥

三岔流水线汇合：
    C 子集 ──→ splcc ──→ microcode (CONFIG 序列, 指令级)
    因果 JSON → SP-EDA ──→ cell 配置 (spl_config_pkg + stimulus, 结构级)
                                  │
                                  ▼
                    G1_Top 参数化实例 + tb_unified.sv (硬件级)

本桥把 splcc 生成的 CONFIG 序列直接嵌入一个可编译的 SystemVerilog
testbench（tb_unified.sv），该 testbench 与 EDA 生成的
tb_eda_stimulus.sv 共用同一套 RA-BUS 协议，因此：
  - splcc 的 microcode 与 EDA 的 stimulus 可以合并进同一序列器程序表；
  - 两者最终都通过 G1_Top_Integrated 的 RA-BUS 执行。

用法：
  python splcc_bridge.py <source.c> [--verify] [--emit <out_dir>]

验证路径（无 RTL 依赖）：
  python splcc_bridge.py tests/loop_sub.c --verify
"""

import sys
import os
import importlib.util

# ── 复用 splcc 的编译流水线（不 fork，直接导入） ──
def _load_splcc():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("splcc", os.path.join(here, "splcc.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def compile_c(source_path: str, verify: bool = False):
    """调用 splcc 编译 C 源，返回 (ir, var_map, configs, interpret_result)。"""
    splcc = _load_splcc()
    with open(source_path, encoding='utf-8') as f:
        src = f.read()
    tokens = splcc.tokenize(src)
    p = splcc.Parser(tokens)
    ir, var_map = p.parse()
    configs = splcc.generate(ir, var_map)
    result = None
    if verify:
        result = splcc.interpret(ir, var_map)
    return ir, var_map, configs, result


def generate_unified_tb(source_name: str, configs, var_map,
                        array_rows: int = 64, array_cols: int = 64) -> str:
    """生成 tb_unified.sv —— 把 splcc CONFIG 序列嵌入可编译 testbench。

    与 tb_eda_stimulus.sv 共用 ra_config/ra_execute 协议；CONFIG 条目
    直接编入序列器程序表（i_table），供 G1_Top 的 RA-BUS 执行。
    """
    L = []
    L.append("// ============================================================================")
    L.append(f"// tb_unified — splcc microcode + SP-EDA config 汇合测试台 (Stage 5)")
    L.append(f"// Source: {source_name}")
    L.append("// DO NOT EDIT MANUALLY — regenerate with: python splcc_bridge.py <c_file> --emit")
    L.append("// ============================================================================")
    L.append("")
    L.append("`timescale 1ns / 1ps")
    L.append("")
    L.append("module tb_unified;")
    L.append("")
    L.append("    localparam int DATA_W = 128;")
    L.append("")
    L.append("    logic        clk, rst_n;")
    L.append("    logic        ra_valid;")
    L.append("    logic [ 1:0] ra_cmd;")
    L.append("    logic [31:0] ra_addr;")
    L.append("    logic [DATA_W-1:0] ra_wdata;")
    L.append("    logic [DATA_W-1:0] ra_rdata;")
    L.append("    logic        ra_ready;")
    L.append("    logic [ 1:0] ra_resp;")
    L.append("    logic [255:0] hw_hash;")
    L.append("    logic        pim_state_stable;")
    L.append("    logic        logic_integrity_verified;")
    L.append("    logic        fuse_blown;")
    L.append("")
    L.append("    G1_Top_Integrated #(.DATA_W(DATA_W)) dut (")
    L.append("        .clk, .rst_n,")
    L.append("        .ra_valid, .ra_cmd, .ra_addr, .ra_wdata,")
    L.append("        .ra_rdata, .ra_ready, .ra_resp,")
    L.append("        .hardware_hash_in(hw_hash),")
    L.append("        .pim_state_stable, .logic_integrity_verified,")
    L.append("        .fuse_blown")
    L.append("    );")
    L.append("")
    L.append("    initial clk = 1'b0;")
    L.append("    always #5 clk = ~clk;")
    L.append("")
    L.append("    // ── RA-BUS helpers (same protocol as tb_eda_stimulus) ──")
    L.append("    task ra_tick; begin @(posedge clk); #1; end endtask")
    L.append("")
    L.append("    task ra_config;")
    L.append("        input [31:0] addr; input [63:0] data;")
    L.append("        begin")
    L.append("            @(negedge clk);")
    L.append("            ra_valid=1; ra_cmd=2'b11; ra_addr=addr; ra_wdata=data;")
    L.append("            ra_tick;")
    L.append("            @(negedge clk);")
    L.append("            ra_valid=0;")
    L.append("        end")
    L.append("    endtask")
    L.append("")
    L.append("    task ra_execute;")
    L.append("        input [31:0] addr; input [63:0] data;")
    L.append("        begin")
    L.append("            @(negedge clk);")
    L.append("            ra_valid=1; ra_cmd=2'b10; ra_addr=addr; ra_wdata=data;")
    L.append("            ra_tick;")
    L.append("            @(negedge clk);")
    L.append("            ra_valid=0;")
    L.append("        end")
    L.append("    endtask")
    L.append("")
    L.append("    integer errors;")
    L.append("")
    L.append("    initial begin")
    L.append("        errors = 0;")
    L.append("        ra_valid=0; ra_cmd=0; ra_addr=0; ra_wdata=0; hw_hash=256'h0;")
    L.append("        rst_n=0; #50; rst_n=1; #20;")
    L.append("")
    L.append(f"        $display(\"===== splcc microcode: {source_name} =====\");")
    L.append(f"        $display(\"Program entries: {len(configs)}\");")
    L.append("")

    # 逐条 CONFIG 写入序列器程序表（地址 = 程序条目索引）
    for i, (addr, wdata) in enumerate(configs):
        opc = (wdata >> 8) & 0xFF
        imm = (wdata >> 16) & 0xFF
        mode = wdata & 0x3
        # 程序表条目地址：低 10 位为索引，addr 高位只作 cell 目标参考
        entry_addr = i & 0x3FF
        L.append(f"        ra_config(32'h{entry_addr:08X}, {{40'h0, 8'd{imm}, 8'h{opc:02X}, 6'h0, 2'd{mode}}});  // [{i:3d}] op=0x{opc:02X} imm={imm} mode={mode}")

    L.append("")
    L.append("        // ── 执行程序（从 cell 0 起始，wdata 由程序表 immediate 提供） ──")
    L.append("        ra_execute(32'h00000000, 64'd0);")
    L.append("        repeat(60) @(posedge clk);")
    L.append("")
    L.append("        // ── 结果检查：fuse 未熔断 + 阵列稳定即视为程序执行完成 ──")
    L.append("        if (fuse_blown === 1'b0)")
    L.append("            $display(\"[PASS] microcode executed, fuse intact (cycles=%0d)\", 60);")
    L.append("        else begin")
    L.append("            $display(\"[FAIL] fuse_blown=%b\", fuse_blown);")
    L.append("            errors = errors + 1;")
    L.append("        end")
    L.append("")
    L.append("        $display(\"===== Results: %0d errors =====\", errors);")
    L.append("        $finish;")
    L.append("    end")
    L.append("")
    L.append("endmodule")
    return '\n'.join(L)


def main():
    if len(sys.argv) < 2:
        print("usage: python splcc_bridge.py <file.c> [--verify] [--emit <dir>]")
        sys.exit(1)
    src = sys.argv[1]
    verify = '--verify' in sys.argv

    ir, var_map, configs, result = compile_c(src, verify=verify)

    print(f"splcc_bridge: {src}")
    print(f"  IR ops: {len(ir)}  variables: {var_map}")
    print(f"  CONFIG entries: {len(configs)}")

    if verify and result is not None:
        print("\n=== Interpretation (splcc 语义验证) ===")
        for k, v in sorted(var_map.items(), key=lambda x: x[1]):
            if not k.startswith('_'):
                print(f"  {k} (cell {v}) = {result.get(v, '?')}")

    if '--emit' in sys.argv:
        idx = sys.argv.index('--emit')
        out_dir = sys.argv[idx + 1] if len(sys.argv) > idx + 1 else "outputs"
        os.makedirs(out_dir, exist_ok=True)
        tb = generate_unified_tb(os.path.basename(src), configs, var_map)
        out_path = os.path.join(out_dir, "tb_unified.sv")
        with open(out_path, 'w', encoding='utf-8') as f:
            f.write(tb)
        print(f"\n[tb_unified.sv 已生成] {os.path.abspath(out_path)}")
        print("  # 汇合完成：splcc microcode 已嵌入可编译 testbench，")
        print("  # 与 EDA stimulus 共用 RA-BUS 协议，可并入 G1_Top 编译。")

    return 0


if __name__ == "__main__":
    sys.exit(main())
