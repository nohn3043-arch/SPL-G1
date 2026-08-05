// ============================================================================
// spl_pim_sequencer_v4 — Micro-Op Sequencer + Control Flow (v4: PPCU Extension)
// ============================================================================
// v4 adds control-flow (JMP/JZ/JNZ/CALL/RET) + 256-entry parameterized
// program memory (PROG_DEPTH). Retains v3 causal audit closed loop.
//
// Control-flow opcodes (0xF0–0xFF): decoded locally — no pim_en, no audit.
//   0xF0 JMP  <target>  — unconditional jump
//   0xF1 JZ   <target>  — jump if pim_flag==1 (result zero)
//   0xF2 JNZ  <target>  — jump if pim_flag==0 (result non-zero)
//   0xF3 CALL <target>  — push return addr, jump to target
//   0xF4 RET             — pop return addr, return
//   0xF5 HALT            — end sequence (not yet in ISA spec; treated as DONE)
//
// Instruction table entry expanded: {op[15:8], immediate[23:16], mode[1:0]}
//   - ra_wdata[15:8]  → i_table_op[pc]      (opcode)
//   - ra_wdata[23:16] → i_table_imm[pc]     (immediate / jump target)
//   - ra_wdata[1:0]   → i_table_mode[pc]    (exec mode)
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_pim_sequencer #(
    parameter int PROG_DEPTH = 256,
    parameter int RET_STACK_DEPTH = 8,
    parameter int DATA_W = 64        // v3: data width (64=legacy, 128=expanded)
) (
    input  logic         clk,
    input  logic         rst_n,

    // ── RA-BUS command interface ──
    input  logic         ra_cmd_valid,
    input  logic [ 1:0]  ra_cmd,           // 00:READ 01:WRITE 10:EXECUTE 11:CONFIG
    input  logic [31:0]  ra_addr,
    input  logic [DATA_W-1:0] ra_wdata,

    // ── Causal audit feedback (v3: closed loop) ──
    input  logic         audit_done,        // causal unit finished checking this op
    input  logic         audit_pass,        // causal unit check result (1=pass)

    // ── PIM zero flag (v4: for JZ/JNZ branching) ──
    input  logic         pim_flag,          // result==0 flag from PIM array (latched)

    // ── Busy / done handshake ──
    output logic         seq_busy,
    output logic         seq_done,
    output logic         seq_error,

    // ── PIM array drive ──
    output logic         pim_en,            // array enable (pulses per op)
    output logic [31:0]  pim_addr,          // ra_addr passthrough
    output logic [DATA_W-1:0] pim_wdata,    // operand
    output logic [ 7:0]  pim_op,            // micro-op
    output logic [ 1:0]  exec_mode,         // SCALAR / VECTOR / MATRIX

    // ── Audit dispatch pulse (connects to causal unit wr_en) ──
    output logic         audit_dispatch,

    // ── Aggregated causal tags → for audit pipeline ──
    output logic [ 7:0]  gen_p_tag,
    output logic [ 7:0]  gen_q_tag
);

    // ── Control-flow opcode constants ──
    localparam logic [7:0] OP_JMP  = 8'hF0;
    localparam logic [7:0] OP_JZ   = 8'hF1;
    localparam logic [7:0] OP_JNZ  = 8'hF2;
    localparam logic [7:0] OP_CALL = 8'hF3;
    localparam logic [7:0] OP_RET  = 8'hF4;
    localparam logic [7:0] OP_HALT = 8'hF5;

    // ── Instruction table (parameterized, CONFIG-writable) ──
    logic [ 7:0] i_table_op   [0:PROG_DEPTH-1];
    logic [ 7:0] i_table_imm  [0:PROG_DEPTH-1];
    logic [ 1:0] i_table_mode [0:PROG_DEPTH-1];

    // ── Return stack (for CALL/RET) ──
    logic [$clog2(PROG_DEPTH)-1:0] ret_stack [0:RET_STACK_DEPTH-1];
    logic [$clog2(RET_STACK_DEPTH)-1:0] ret_sp;

    // ── Sequencer state ──
    typedef enum logic [2:0] {
        SEQ_IDLE         = 3'b000,
        SEQ_CONFIG       = 3'b001,
        SEQ_EXEC         = 3'b010,
        SEQ_AUDIT_WAIT   = 3'b011,   // v3: wait for causal unit response
        SEQ_PC_UPDATE    = 3'b110,   // v4: control-flow PC update (no PIM dispatch)
        SEQ_READ         = 3'b111,   // v5: RA-BUS READ transaction
        SEQ_DONE         = 3'b100,
        SEQ_ERR          = 3'b101
    } seq_state_t;

    seq_state_t state, next_state;

    logic [$clog2(PROG_DEPTH)-1:0] pc;       // program counter
    logic [$clog2(PROG_DEPTH)-1:0] seq_len;  // configured sequence length
    logic is_control_op;                       // current op is control-flow (no PIM dispatch)

    assign is_control_op = (i_table_op[pc] >= 8'hF0);

    // ── State machine (FF) ──
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= SEQ_IDLE;
            pc     <= '0;
            ret_sp <= '0;
            for (int i = 0; i < RET_STACK_DEPTH; i++) ret_stack[i] <= '0;
        end else begin
            state <= next_state;
            case (state)
                SEQ_IDLE: begin
                    pc     <= '0;
                    ret_sp <= '0;
                end

                SEQ_AUDIT_WAIT: begin
                    if (audit_done && audit_pass && pc < seq_len - 1)
                        pc <= pc + 1'b1;   // normal advance
                end

                SEQ_PC_UPDATE: begin
                    // Control-flow PC update
                    case (i_table_op[pc])
                        OP_JMP:  pc <= i_table_imm[pc];
                        OP_JZ:   pc <= pim_flag ? i_table_imm[pc] : pc + 1'b1;
                        OP_JNZ:  pc <= (~pim_flag) ? i_table_imm[pc] : pc + 1'b1;
                        OP_CALL: begin
                            ret_sp <= ret_sp + 1'b1;
                            ret_stack[ret_sp] <= pc + 1'b1;
                            pc <= i_table_imm[pc];
                        end
                        OP_RET: begin
                            ret_sp <= ret_sp - 1'b1;
                            pc <= ret_stack[ret_sp - 1'b1];
                        end
                        OP_HALT: pc <= seq_len;   // will trigger DONE on next check
                        default: pc <= pc + 1'b1; // fallback
                    endcase
                end

                SEQ_DONE: begin
                    pc     <= '0;
                    ret_sp <= '0;
                end

                SEQ_ERR: begin
                    pc     <= '0;
                    ret_sp <= '0;
                end

                default: ;
            endcase
        end
    end

    // ── Next-state logic (v4: control-flow dispatch) ──
    always_comb begin
        next_state = state;
        case (state)
            SEQ_IDLE: begin
                if (ra_cmd_valid && ra_cmd == 2'b10)       next_state = SEQ_EXEC;
                else if (ra_cmd_valid && ra_cmd == 2'b11)  next_state = SEQ_CONFIG;
                else if (ra_cmd_valid && ra_cmd == 2'b00)  next_state = SEQ_READ;
            end
            SEQ_CONFIG: next_state = SEQ_DONE;

            SEQ_EXEC: begin
                if (pc >= seq_len)              // OOB (after branch or HALT)
                    next_state = SEQ_DONE;
                else if (is_control_op)
                    next_state = SEQ_PC_UPDATE; // v4: no PIM dispatch for control ops
                else
                    next_state = SEQ_AUDIT_WAIT;  // normal compute → audit handshake
            end

            SEQ_AUDIT_WAIT: begin
                if (audit_done && audit_pass) begin
                    if (pc < seq_len - 1)
                        next_state = SEQ_EXEC;  // issue next op
                    else
                        next_state = SEQ_DONE;  // all ops passed
                end else if (audit_done && !audit_pass) begin
                    next_state = SEQ_ERR;       // audit failure → halt
                end
                // else: stay in SEQ_AUDIT_WAIT
            end

            SEQ_PC_UPDATE: begin
                // After control-flow PC update, re-enter EXEC at updated PC.
                // HALT is the only control op that terminates.
                if (i_table_op[pc] == OP_HALT)
                    next_state = SEQ_DONE;
                else
                    next_state = SEQ_EXEC;
            end

            SEQ_DONE:  next_state = SEQ_IDLE;
            SEQ_ERR:   next_state = SEQ_IDLE;
            SEQ_READ:  next_state = SEQ_DONE;      // v5: single-cycle read → done
            default:   next_state = SEQ_IDLE;
        endcase
    end

    // ── Output logic ──
    always_comb begin
        // defaults
        pim_en          = 1'b0;
        pim_op          = 8'h00;
        pim_addr        = 32'h0;
        pim_wdata       = {DATA_W{1'b0}};
        exec_mode       = 2'b00;
        seq_busy        = 1'b0;
        seq_done        = 1'b0;
        seq_error       = 1'b0;
        audit_dispatch  = 1'b0;

        case (state)
            SEQ_IDLE: begin
                // idle
            end

            SEQ_CONFIG: begin
                // Write instruction table entry
            end

            SEQ_EXEC: begin
                seq_busy = 1'b1;
                if (is_control_op) begin
                    // v4: control ops — no PIM dispatch, no audit
                    pim_en    = 1'b0;
                    pim_op    = i_table_op[pc];
                    exec_mode = i_table_mode[pc];
                end else begin
                    // Normal compute op
                    pim_en          = 1'b1;
                    pim_op          = i_table_op[pc];
                    exec_mode       = i_table_mode[pc];
                    pim_addr        = ra_addr;
                    pim_wdata       = i_table_imm[pc];
                    audit_dispatch  = 1'b1;
                end
            end

            SEQ_AUDIT_WAIT: begin
                seq_busy   = 1'b1;
                pim_addr   = ra_addr;
                pim_wdata  = i_table_imm[pc];
            end

            SEQ_PC_UPDATE: begin
                seq_busy = 1'b1;
            end

            SEQ_DONE: begin
                seq_done = 1'b1;
            end

            SEQ_ERR: begin
                seq_error = 1'b1;
                seq_done  = 1'b1;
            end

            SEQ_READ: begin
                // v5: NOP on target cell → array outputs ra_rdata → bus readback
                seq_busy   = 1'b1;
                pim_en     = 1'b1;
                pim_op     = 8'h00;      // NOP (read without store)
                exec_mode  = 2'b01;      // SCALAR: single-cell read
                pim_addr   = ra_addr;
                pim_wdata   = 64'h0;     // no store
            end
        endcase
    end

    // ── Instruction table programming (CONFIG command) ──
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < PROG_DEPTH; i++) begin
                i_table_op[i]   <= 8'h00;
                i_table_imm[i]  <= 8'h00;
                i_table_mode[i] <= 2'b00;
            end
            seq_len <= '0;
        end else if (state == SEQ_CONFIG) begin
            i_table_op[ra_addr[$clog2(PROG_DEPTH)-1:0]]   <= ra_wdata[15:8];
            i_table_imm[ra_addr[$clog2(PROG_DEPTH)-1:0]]  <= ra_wdata[23:16];
            i_table_mode[ra_addr[$clog2(PROG_DEPTH)-1:0]] <= ra_wdata[1:0];
            // Track sequence length: highest written index + 1
            if (ra_addr[$clog2(PROG_DEPTH)-1:0] + 1'b1 > seq_len)
                seq_len <= ra_addr[$clog2(PROG_DEPTH)-1:0] + 1'b1;
        end
    end

    // ── Causal tag passthrough ──
    assign gen_p_tag = i_table_op[pc];
    assign gen_q_tag = pim_op;

endmodule
