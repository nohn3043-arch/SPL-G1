#!/usr/bin/env python3
"""
splcc v0.1 — SPL-G1 TCU C-subset Compiler
==========================================
Compiles a restricted C dialect to SPL-G1 microcode (CONFIG hex words).

Supports:  int variables, for/while loops, if/else, + - * = == != < >
           No functions. No pointers. No arrays (v0.2).

Usage:  python splcc.py <source.c>           → stdout hex listing
        python splcc.py <source.c> --json    → JSON output
        python splcc.py <source.c> --verify  → compile + run interpreter

Example input (tests/loop_sum.c):
    int main() {
        int sum = 0;
        for (int i = 5; i > 0; i = i - 1)
            sum = sum + 1;
        return sum;
    }
"""

import sys, json, re
from collections import namedtuple

# ── SPL-G1 ISA opcodes ──────────────────────────────────────
OP = {
    "NOP":  0x00, "ADD": 0x01, "SUB": 0x03, "MUL": 0x05,
    "CMP_EQ": 0x08, "CMP_NE": 0x09, "CMP_LT": 0x0A, "CMP_GT": 0x0B,
    "STORE":  0x1B,
    "JZ": 0xF2, "JNZ": 0xF1, "JMP": 0xF0, "HALT": 0xF5,
}
MODE = {"SCALAR": 1, "VECTOR": 2, "MATRIX": 3}
IR = namedtuple("IR", ["op", "dest", "src1", "src2", "imm"])

# ── Tokenizer ────────────────────────────────────────────────
TOK_PAT = re.compile(r'\b(int|for|if|else|while|return)\b|'
                     r'[a-zA-Z_]\w*|'
                     r'\d+|'
                     r'[+\-*/<>=;(){}=!]|'
                     r'<=|>=|==|!=')

def tokenize(src):
    return [m.group() for m in TOK_PAT.finditer(src) if m.group() not in (' ', '\t', '\n', '\r')]

# ── Parser → IR ──────────────────────────────────────────────
class Parser:
    def __init__(self, tokens):
        self.t = tokens
        self.i = 0
        self.ir = []
        self.vars = {}       # name → cell_id (0..15)
        self.next_cell = 0
        self.label_ctr = 0

    def peek(self): return self.t[self.i] if self.i < len(self.t) else None
    def eat(self, s=None):
        t = self.t[self.i]; self.i += 1
        if s and t != s: raise SyntaxError(f"expected '{s}', got '{t}'")
        return t

    def alloc_var(self, name):
        if name not in self.vars:
            self.vars[name] = self.next_cell
            self.next_cell += 1
        return self.vars[name]

    def new_label(self):
        self.label_ctr += 1
        return self.label_ctr

    def parse_expr(self):
        """expr → term { ('<' | '>' | '<=' | '>=' | '==' | '!=') term }"""
        lhs = self.parse_term()
        while self.peek() in ('<', '>', '<=', '>=', '==', '!='):
            op = self.eat()
            rhs = self.parse_term()
            t = self.alloc_var('_t%d' % self.label_ctr)
            op_map = {'<':'CMP_LT','>':'CMP_GT','==':'CMP_EQ','!=':'CMP_NE','<=':'CMP_GT','>=':'CMP_LT'}
            cmp_op = op_map[op]
            if op in ('<=', '>='):
                # a <= b  →  b >= a  →  CMP_GT swapped
                self.ir.append(IR(cmp_op, t, rhs, lhs, 0))
            else:
                self.ir.append(IR(cmp_op, t, lhs, rhs, 0))
            lhs = t
        return lhs

    def parse_term(self):
        """term → factor { ('+'|'-') factor }"""
        lhs = self.parse_factor()
        while self.peek() in ('+', '-'):
            op = self.eat()
            rhs = self.parse_factor()
            t = self.alloc_var('_t%d' % self.label_ctr)
            self.ir.append(IR("SUB" if op == '-' else "ADD", t, lhs, rhs, 0))
            lhs = t
        return lhs

    def parse_factor(self):
        """factor → atom { ('*'|'/') atom }"""
        lhs = self.parse_atom()
        while self.peek() in ('*', '/'):
            op = self.eat(); rhs = self.parse_atom()
            t = self.alloc_var('_t%d' % self.label_ctr)
            self.ir.append(IR("MUL" if op == '*' else "DIV", t, lhs, rhs, 0))
            lhs = t
        return lhs

    def parse_atom(self):
        t = self.peek()
        if t and t.isdigit():
            self.eat()
            tn = self.alloc_var('_c%d' % self.label_ctr)
            self.ir.append(IR("NOP", tn, None, None, int(t)))
            return tn
        if t and re.match(r'[a-zA-Z_]', t):
            name = self.eat()
            return self.alloc_var(name)
        if t == '(':
            self.eat(); e = self.parse_expr(); self.eat(')')
            return e
        raise SyntaxError(f"unexpected '{t}'")

    def parse_stmt(self):
        t = self.peek()
        # Compound statement: { stmt* }
        if t == '{':
            self.eat()
            while self.peek() != '}':
                self.parse_stmt()
            self.eat('}')
            return
        if t == 'int':
            self.eat(); name = self.eat()
            c = self.alloc_var(name)
            if self.peek() == '=':
                self.eat(); val = int(self.eat()); self.ir.append(IR("NOP", c, None, None, val))
            self.eat(';')
            return
        if t == 'if':
            self.eat(); self.eat('('); cond = self.parse_expr(); self.eat(')')
            jmp_label = self.new_label()
            self.ir.append(IR("JZ", '_j%d' % jmp_label, cond, None, jmp_label))
            self.parse_stmt()
            if self.peek() == 'else':
                self.eat()
                end_label = self.new_label()
                self.ir.append(IR("JMP", '_j%d' % end_label, None, None, end_label))
                self.ir.append(IR("LABEL", '_j%d' % jmp_label, None, None, 0))
                self.parse_stmt()
                self.ir.append(IR("LABEL", '_j%d' % end_label, None, None, 0))
            else:
                self.ir.append(IR("LABEL", '_j%d' % jmp_label, None, None, 0))
            return
        if t == 'for':
            self.eat(); self.eat('(');
            if self.peek() == 'int':
                self.eat(); name = self.eat(); self.eat('='); init = int(self.eat())
                c = self.alloc_var(name); self.ir.append(IR("NOP", c, None, None, init))
            else:
                self.parse_expr(); self.eat(';')
            self.eat(';')
            loop_l = self.new_label(); self.ir.append(IR("LABEL", '_l%d' % loop_l, None, None, 0))
            cond = self.parse_expr(); self.eat(';')
            end_l = self.new_label()
            self.ir.append(IR("JZ", '_j%d' % end_l, cond, None, end_l))
            if self.peek() == 'int':
                pass
            step_var = self.peek(); self.eat(); self.eat('='); step_var_cell = self.alloc_var(step_var)
            step_expr = self.parse_expr()
            if self.peek() == ')': self.eat()
            if step_expr != step_var:
                self.ir.append(IR("NOP", step_var_cell, None, None, 0))
                self.ir.append(IR("NOP", step_var_cell, step_var_cell, None, 0))
            self.parse_stmt()
            self.ir.append(IR("JMP", '_j%d' % loop_l, None, None, loop_l))
            self.ir.append(IR("LABEL", '_j%d' % end_l, None, None, 0))
            return
        if t == 'while':
            self.eat(); self.eat('(')
            loop_l = self.new_label(); self.ir.append(IR("LABEL", '_l%d' % loop_l, None, None, 0))
            cond = self.parse_expr(); self.eat(')')
            end_l = self.new_label()
            self.ir.append(IR("JZ", '_j%d' % end_l, cond, None, end_l))
            self.parse_stmt()
            self.ir.append(IR("JMP", '_j%d' % loop_l, None, None, loop_l))
            self.ir.append(IR("LABEL", '_j%d' % end_l, None, None, 0))
            return
        if t in ('return',):
            self.eat()
            if self.peek() == ';': self.eat()
            else: self.parse_expr(); self.eat(';')
            self.ir.append(IR("HALT", None, None, None, 0))
            return
        # assignment or expression statement
        if re.match(r'[a-zA-Z_]', t):
            name = self.eat()
            if self.peek() == '=':
                self.eat(); c = self.alloc_var(name)
                rhs = self.parse_expr()
                if rhs != name:
                    self.ir.append(IR("NOP", c, None, None, 0))  # clear
                    self.ir.append(IR("NOP", c, rhs, None, 0))   # assign
            self.eat(';')
            return
        if t == ';': self.eat(); return
        raise SyntaxError(f"unknown statement '{t}'")

    def parse(self):
        while self.peek() and self.peek() != 'int':
            self.eat()
        if self.peek() == 'int': self.eat()
        if self.peek() == 'main': self.eat()
        if self.peek() == '(': self.eat()
        if self.peek() == ')': self.eat()
        self.eat('{')
        while self.peek() != '}':
            self.parse_stmt()
        self.eat('}')
        self.ir.append(IR("HALT", None, None, None, 0))
        return self.ir, self.vars

# ── Code Generator: IR → CONFIG hex words ───────────────────
def generate(ir, var_map):
    """Emit CONFIG commands (ra_addr, ra_wdata hex pairs) for each IR op."""
    lbl_map = {}  # label → PC
    pc = 0
    configs = []

    # Pass 1: collect label positions
    for instr in ir:
        if instr.op == "LABEL":
            lbl_map[instr.dest] = pc
        else:
            pc += 1

    # Pass 2: emit
    prev_op = None
    prev_dest = None
    for instr in ir:
        if instr.op == "LABEL":
            continue

        # Determine cell address for dest
        if instr.dest and (instr.dest in var_map or (instr.op in ("JMP","JZ","JNZ") and isinstance(instr.imm, int))):
            cell_id = var_map.get(instr.dest, 0) if instr.dest in var_map else 0
            addr = (cell_id & 0xFF) << 16
        else:
            addr = 0

        # Build opcode
        if instr.op in OP:
            opc = OP[instr.op]
        elif instr.op == "NOP" and instr.dest and instr.src1:
            # assignment: move src1 value → dest
            opc = OP["ADD"]   # ADD with zero is effectively move
            src_addr = (var_map.get(instr.src1, 0) & 0xFF) << 16 if instr.src1 else 0
            # hack: for simple assignment, use NOP with immediate
            if not instr.src1:
                opc = OP["NOP"]
                addr = (var_map.get(instr.dest, 0) & 0xFF) << 16
                configs.append((addr, opc, 1, instr.imm if instr.imm else 0))
                continue
            opc = OP["NOP"]
        else:
            opc = OP.get(instr.op, 0)

        imm = instr.imm if instr.imm else 0
        mode = MODE["SCALAR"]

        # Branch target resolution
        if instr.op in ("JMP", "JZ", "JNZ"):
            target_label = '_j%d' % instr.imm if isinstance(instr.imm, int) else instr.imm
            imm = lbl_map.get(target_label, instr.imm) if isinstance(instr.imm, int) else lbl_map.get(str(instr.imm), 0)
            mode = MODE["SCALAR"]
            opc = OP[instr.op]

        # Pack: ra_wdata[23:16]=imm, [15:8]=op, [1:0]=mode
        wdata = ((imm & 0xFF) << 16) | ((opc & 0xFF) << 8) | (mode & 0x3)
        configs.append((addr if addr else 0, wdata))

    return configs

# ── Interpreter: verify correctness ─────────────────────────
def interpret(ir, var_map):
    cells = {}
    pc = 0
    step = 0
    labels = {}
    for i, instr in enumerate(ir):
        if instr.op == "LABEL":
            labels[instr.dest] = i
    for v, cid in var_map.items():
        cells[cid] = 0

    while pc < len(ir) and step < 10000:
        instr = ir[pc]
        step += 1
        if instr.op == "LABEL":
            pc += 1; continue
        if instr.op == "HALT":
            break
        v_d = cells.get(instr.dest, 0) if instr.dest in cells else 0
        v_s1 = cells.get(instr.src1, 0) if instr.src1 in cells else (instr.imm if instr.imm else 0)
        v_s2 = cells.get(instr.src2, 0) if instr.src2 else 0

        if instr.op == "NOP":
            if instr.imm:
                cells[instr.dest] = instr.imm
            elif instr.src1:
                cells[instr.dest] = cells.get(instr.src1, 0)
        elif instr.op == "ADD": cells[instr.dest] = v_s1 + v_s2
        elif instr.op == "SUB": cells[instr.dest] = v_s1 - v_s2
        elif instr.op == "MUL": cells[instr.dest] = v_s1 * v_s2
        elif instr.op == "CMP_EQ": cells[instr.dest] = 1 if v_s1 == v_s2 else 0
        elif instr.op == "CMP_NE": cells[instr.dest] = 1 if v_s1 != v_s2 else 0
        elif instr.op == "CMP_LT": cells[instr.dest] = 1 if v_s1 < v_s2 else 0
        elif instr.op == "CMP_GT": cells[instr.dest] = 1 if v_s1 > v_s2 else 0
        elif instr.op == "JMP":
            target = labels.get('_j%d' % instr.imm, 0)
            pc = target; continue
        elif instr.op == "JZ":
            if cells.get(instr.src1, 0) == 0:
                pc = labels.get('_j%d' % instr.imm, pc)
                continue
        elif instr.op == "JNZ":
            if cells.get(instr.src1, 0) != 0:
                pc = labels.get('_j%d' % instr.imm, pc)
                continue
        pc += 1
    return cells

# ── CLI ──────────────────────────────────────────────────────
def main():
    if len(sys.argv) < 2:
        print("usage: python splcc.py <file.c> [--json|--verify]")
        sys.exit(1)

    src_file = sys.argv[1]
    with open(src_file, encoding='utf-8') as f:
        src = f.read()

    tokens = tokenize(src)
    p = Parser(tokens)
    ir, var_map = p.parse()

    if '--verify' in sys.argv:
        cells = interpret(ir, var_map)
        print("=== Interpretation ===")
        for k, v in sorted(var_map.items(), key=lambda x: x[1]):
            if not k.startswith('_'):
                print(f"  {k} (cell {v}) = {cells.get(v, '?')}")
        return

    configs = generate(ir, var_map)

    if '--json' in sys.argv:
        out = []
        for addr, wdata in configs:
            out.append({"addr": f"0x{addr:08X}", "wdata": f"0x{wdata:016X}"})
        print(json.dumps(out, indent=2))
    else:
        print(f"// splcc v0.1 — {src_file} → SPL-G1 microcode ({len(configs)} ops)")
        print(f"// Variables: {var_map}")
        for i, (addr, wdata) in enumerate(configs):
            opc = (wdata >> 8) & 0xFF
            imm = (wdata >> 16) & 0xFF
            mode = wdata & 0x3
            opname = [k for k,v in OP.items() if v==opc] or [f"0x{opc:02X}"]
            print(f"ra_config(32'h{addr:08X}, {{40'h0, 8'd{imm}, 8'h{opc:02X}, 6'h0, 2'd{mode}}});  // [{i:3d}] {opname[0]}")

    # Also write ra_execute line
    print(f"\n// Execute: ra_execute(32'h00000000, 64'd0);")

if __name__ == "__main__":
    main()
