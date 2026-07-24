// ============================================================================
// spl_cim_causal_unit_v2 — Causal Audit Unit (Drop-in replacement for v1)
// ============================================================================
// Replaces magic-number detection with constraint-based checking.
//
// Causal Record Wire Format (packed into wr_data_p + wr_data_q):
//   wr_data_p[255:248] = rule_id           — constraint rule hash prefix
//   wr_data_p[247:192] = dep_mask          — 56-bit dependency bitmask (1=required)
//   wr_data_p[191:128] = constraint_bits   — 64-bit hard-constraint pass (1=OK)
//   wr_data_p[127:64]  = weight_q16_16     — weight/sensitivity (Q16.16)
//   wr_data_q[63:0]    = provenance_lo     — provenance chain hash
//
// logic_valid = constraint_pass ∧ dep_valid
//   constraint_pass = (constraint_bits == 64'hFFFF_FFFF_FFFF_FFFF)
//   dep_valid       = (dep_mask & ~premise_state) == 0
//
// Cascade: when check fails, dep_mask bits become invalid in premise_state.
// Pass-through mode (no constraint rules configured): constraint_bits = all-1s → always passes.
//
// Port interface: identical to spl_cim_causal_unit for drop-in.
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_cim_causal_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        wr_en,
    input  logic [255:0] wr_data_p,
    input  logic [255:0] wr_data_q,
    output logic        logic_valid,
    output logic        check_done,     // 1 = check finished (S_VALID or S_CASCADE)
    output logic        check_pass      // 1 = check passed (valid_reg in S_VALID)
);

    // ── Field extraction ──
    wire [ 7:0] rule_id         = wr_data_p[255:248];
    wire [55:0] dep_mask        = wr_data_p[247:192];
    wire [63:0] constraint_bits = wr_data_p[191:128];
    wire [63:0] weight_q16_16   = wr_data_p[127:64];
    wire [63:0] provenance_lo   = wr_data_q[63:0];

    // ── Hard constraint check ──
    wire constraint_pass;
    assign constraint_pass = (constraint_bits == 64'hFFFF_FFFF_FFFF_FFFF);

    // ── Dependency check ──
    logic [55:0] premise_state;   // 1=valid, 0=invalid
    wire  [55:0] active_fails;
    wire         dep_valid;

    assign active_fails = dep_mask & ~premise_state;
    assign dep_valid    = (active_fails == 56'h0);

    // ── Final ──
    wire final_pass;
    assign final_pass = constraint_pass && dep_valid;

    // ── Cascade ──
    logic [55:0] cascade_invalidate;
    assign cascade_invalidate = final_pass ? 56'h0 : dep_mask;

    // ── FSM ──
    typedef enum logic [2:0] {
        S_IDLE = 3'd0, S_CHECK = 3'd1, S_VALID = 3'd2, S_CASCADE = 3'd3
    } state_t;
    state_t state, next_state;

    logic [3:0] init_counter;
    logic       init_done, valid_reg, wr_en_d1, sticky_fail;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_counter  <= 4'd0;
            wr_en_d1      <= 1'b0;
            sticky_fail   <= 1'b0;
            premise_state <= 56'hFFFFFFFFFFFFFF;
        end else begin
            if (init_counter < 4'd8) init_counter <= init_counter + 1;
            wr_en_d1 <= wr_en;
            if (wr_en && !wr_en_d1)                      sticky_fail <= 1'b0;
            if (state == S_CHECK && !final_pass)         sticky_fail <= 1'b1;
            if (state == S_CASCADE && !final_pass)       premise_state <= premise_state & ~cascade_invalidate;
            if (wr_en && state == S_IDLE && wr_data_q[127]) premise_state[55:0] <= wr_data_q[119:64];
        end
    end
    assign init_done = (init_counter >= 4'd8);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= S_IDLE; valid_reg <= 1'b0; end
        else begin
            state <= next_state;
            if (state == S_CHECK) valid_reg <= final_pass;
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            S_IDLE:    if (wr_en && !wr_en_d1) next_state = S_CHECK;
            S_CHECK:                           next_state = S_VALID;
            S_VALID:  if (final_pass)          next_state = S_IDLE;
                      else                     next_state = S_CASCADE;
            S_CASCADE:                         next_state = S_IDLE;
            default:                           next_state = S_IDLE;
        endcase
    end

    assign logic_valid = init_done && !sticky_fail && ((state == S_IDLE) || (state == S_VALID)) && valid_reg;

    // ── Per-check handshake outputs ──
    assign check_done = (state == S_VALID) || (state == S_CASCADE);
    assign check_pass = (state == S_VALID) && valid_reg;

    `ifdef SIMULATION
    always @(posedge clk) begin
        if (wr_en && !wr_en_d1)
            $display("[AUDIT v2] rule=%02x dep=%014x constr=%016x", rule_id, dep_mask, constraint_bits);
        if (state == S_CHECK)
            $display("[AUDIT v2] check: cpass=%b depok=%b final=%b", constraint_pass, dep_valid, final_pass);
        if (state == S_CASCADE)
            $display("[AUDIT v2] cascade: mask=%014x", cascade_invalidate);
    end
    `endif

endmodule
