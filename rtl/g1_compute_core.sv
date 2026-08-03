// SPL-G1 Compute Core  (v0.1.0)
//
// The "body" that the causal-audit pipeline rides on.
// Produces tagged P→Q causal pairs from actual computation.
//
// Operation modes (op_mode):
//   3'd0  NS      Narrative Strip   : isolate logic — operand_a  →  stripped_result
//   3'd1  IAP     Assumption Detect : compare  — operand_a, operand_b  →  match/mismatch
//   3'd2  LCH     Vulnerability     : weighted blend — (a * w + b * (1-w))  →  hedged result
//   3'd3  CCS     Clock Sync        : latch + timestamp  →  synced pair
//   3'd4  STATE   State Update      : accumulate  — old_state + delta  →  new_state
//
// Each operation emits both P (antecedent / cause) and Q (consequent / effect).
// The causal unit downstream audits the validity of P→Q.


module g1_compute_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,               // pulse to begin computation
    input  logic [2:0]  op_mode,             // NS/IAP/LCH/CCS/STATE (0-4)
    input  logic [63:0] operand_a,           // first operand  (premise data)
    input  logic [63:0] operand_b,           // second operand (context / weight / delta)
    input  logic [63:0] timestamp,           // CCS clock reference

    output logic        done,                // high for 1 cycle when result is ready
    output [255:0]      p_tag,               // causal antecedent  P
    output [255:0]      q_tag,               // causal consequent  Q
    output [63:0]       result               // raw compute result (for system integration)
);

    typedef enum logic [1:0] {
        ST_IDLE   = 2'd0,
        ST_COMP   = 2'd1,
        ST_DONE   = 2'd2
    } cstate_t;

    cstate_t cstate, cnext;

    logic [63:0] res_int;

    // ── Compute logic (continuous assignment for iverilog compatibility) ─
    assign res_int = (op_mode == 3'd0) ? operand_a :
                     (op_mode == 3'd1) ? ((operand_a == operand_b) ? 64'd1 : 64'd0) :
                     (op_mode == 3'd2) ? ((operand_a * operand_b[15:0] + operand_b * (64'd65536 - operand_b[15:0])) >> 16) :
                     (op_mode == 3'd3) ? timestamp :
                     (op_mode == 3'd4) ? (operand_a + operand_b) :
                                         operand_a;

    // ── Causal tagging (continuous assignment for iverilog compatibility) ─
    // P = {op_mode, narrative_bits, operand_a, operand_b}
    // Q = {op_mode, status_bits,    result}
    logic [3:0]  top_nibble_mode;
    assign top_nibble_mode = {1'b0, op_mode};              // [3:0]  = op mode tag

    assign p_tag = {top_nibble_mode, 124'd0, operand_a, operand_b};
    assign q_tag = {top_nibble_mode, 60'd0, res_int, res_int, res_int};

    assign result = res_int;

    // ── State machine (2-cycle compute) ────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cstate <= ST_IDLE;
        else
            cstate <= cnext;
    end

    always_comb begin
        cnext = cstate;
        case (cstate)
            ST_IDLE: if (start) cnext = ST_COMP;
            ST_COMP:            cnext = ST_DONE;
            ST_DONE:            cnext = ST_IDLE;
            default:            cnext = ST_IDLE;
        endcase
    end

    assign done = (cstate == ST_DONE);

endmodule
