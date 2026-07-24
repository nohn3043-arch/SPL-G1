// ============================================================================
// spl_pim_sequencer — Micro-Op Sequencer for PIM Compute Array
// ============================================================================
// Drives the PIM array through a sequence of 8-bit micro-ops. The sequencer
// runs when RA-BUS issues an EXECUTE command (ra_cmd == 2'b10). It supports:
//
//   - Single-op immediate execution (ra_cmd EXEC with inline op)
//   - Programmed sequences via the micro-op instruction table (16-entry look-up)
//   - Mode switching: can change exec_mode mid-sequence
//
// Each completed operation produces a causal P→Q pair, consumed by the
// audit pipeline.
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_pim_sequencer (
    input  logic         clk,
    input  logic         rst_n,

    // ── RA-BUS command interface ──
    input  logic         ra_cmd_valid,
    input  logic [ 1:0]  ra_cmd,           // 00:READ 01:WRITE 10:EXECUTE 11:CONFIG
    input  logic [31:0]  ra_addr,
    input  logic [63:0]  ra_wdata,

    // ── Busy / done handshake ──
    output logic         seq_busy,
    output logic         seq_done,
    output logic         seq_error,

    // ── PIM array drive ──
    output logic         pim_en,           // array enable
    output logic [31:0]  pim_addr,         // ra_addr passthrough
    output logic [63:0]  pim_wdata,        // operand
    output logic [ 7:0]  pim_op,           // micro-op
    output logic [ 1:0]  exec_mode,        // SCALAR / VECTOR / MATRIX

    // ── Aggregated causal tags (from array) → for audit pipeline ──
    output logic [ 7:0]  gen_p_tag,
    output logic [ 7:0]  gen_q_tag
);

    // ── Instruction table (16 entries, CONFIG-writable) ──
    logic [ 7:0] i_table_op   [0:15];
    logic [ 1:0] i_table_mode [0:15];

    // ── Sequencer state ──
    typedef enum logic [2:0] {
        SEQ_IDLE    = 3'b000,
        SEQ_CONFIG  = 3'b001,
        SEQ_EXEC    = 3'b010,
        SEQ_DONE    = 3'b011,
        SEQ_ERR     = 3'b100
    } seq_state_t;

    seq_state_t state, next_state;

    logic [3:0] pc;               // program counter
    logic [3:0] seq_len;          // configured sequence length
    logic       seq_trigger;      // start execution

    // ── State machine ──
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= SEQ_IDLE;
            pc    <= 4'd0;
        end else begin
            state <= next_state;
            case (state)
                SEQ_IDLE: begin
                    pc <= 4'd0;
                end
                SEQ_EXEC: begin
                    if (pc < seq_len - 1)
                        pc <= pc + 4'd1;
                    else
                        pc <= 4'd0;
                end
                SEQ_DONE: begin
                    pc <= 4'd0;
                end
                default: pc <= pc;
            endcase
        end
    end

    // ── Next-state logic ──
    always_comb begin
        next_state = state;
        case (state)
            SEQ_IDLE: begin
                if (ra_cmd_valid && ra_cmd == 2'b10)  next_state = SEQ_EXEC;   // EXECUTE
                else if (ra_cmd_valid && ra_cmd == 2'b11) next_state = SEQ_CONFIG; // CONFIG
            end
            SEQ_CONFIG: next_state = SEQ_DONE;
            SEQ_EXEC: begin
                if (pc >= seq_len - 1) next_state = SEQ_DONE;
            end
            SEQ_DONE:  next_state = SEQ_IDLE;
            SEQ_ERR:   next_state = SEQ_IDLE;
            default:   next_state = SEQ_IDLE;
        endcase
    end

    // ── Output logic ──
    always_comb begin
        // defaults
        pim_en     = 1'b0;
        pim_op     = 8'h00;
        pim_addr   = 32'h0;
        pim_wdata  = 64'h0;
        exec_mode  = 2'b00;
        seq_busy   = 1'b0;
        seq_done   = 1'b0;
        seq_error  = 1'b0;

        case (state)
            SEQ_IDLE: begin
                seq_busy = 1'b0;
            end

            SEQ_CONFIG: begin
                // Write instruction table entry
                // ra_addr[3:0] => table index
                // ra_wdata[1:0] => mode, ra_wdata[15:8] => op
            end

            SEQ_EXEC: begin
                seq_busy  = 1'b1;
                pim_en    = 1'b1;
                pim_op    = i_table_op[pc];
                exec_mode = i_table_mode[pc];
                pim_addr  = ra_addr;
                pim_wdata = ra_wdata;

                if (pc >= seq_len) seq_error = 1'b1;
            end

            SEQ_DONE: begin
                seq_done = 1'b1;
            end

            SEQ_ERR: begin
                seq_error = 1'b1;
                seq_done  = 1'b1;
            end
        endcase
    end

    // ── Instruction table programming (CONFIG command) ──
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 16; i++) begin
                i_table_op[i]   <= 8'h00;
                i_table_mode[i] <= 2'b00;
            end
            seq_len <= 4'd1;  // default: single-op mode
        end else if (state == SEQ_CONFIG) begin
            i_table_op[ra_addr[3:0]]   <= ra_wdata[15:8];
            i_table_mode[ra_addr[3:0]] <= ra_wdata[1:0];
            // last CONFIG before EXEC sets sequence length
            if (ra_addr[3:0] == 4'd15)
                seq_len <= 4'd16;
            else if (ra_addr[3:0] >= seq_len)
                seq_len <= ra_addr[3:0] + 4'd1;
        end
    end

    // ── Causal tag passthrough ──
    assign gen_p_tag = i_table_op[pc];
    assign gen_q_tag = pim_op;  // simplified: Q = the micro-op that ran

endmodule
