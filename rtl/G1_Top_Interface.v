// SPL-G1 Top-Level Interface Module  (v0.2.0 — full compute → audit pipeline)
//
// Integrates:
//   1. Hardware Identity Anchor  — 256-bit multi-cycle hash verification
//   2. Compute Core              — g1_compute_core  (produces tagged P→Q pairs)
//   3. Causal Audit Array        — 4× spl_cim_causal_unit  (audits each P→Q pair)
//   4. SBC Sequencer             — orchestrates compute-start → audit-done flow
//
// Pipeline:
//   Host RA-BUS  →  SBC Sequencer  →  Compute Core  →  P/Q Tags  →  Causal Units  →  pim_state_stable
//
// logic_integrity_verified = 1  only after all 256 bits of the identity hash are confirmed.


module G1_Top_Interface (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [511:0] internal_logic_stream,   // {reserved[511:320], op_mode[319:317], operand_a[255:128], operand_b[127:0]}
    input  logic [255:0] hardware_hash_in,         // identity verification nibble
    input  logic         ra_bus_valid,             // RA-BUS write strobe
    input  logic [31:0]  ra_bus_addr,              // [1:0] = unit select; [2] = compute start
    output logic         pim_state_stable,         // all CIM units audit-passed + SBC ready
    output logic         logic_integrity_verified  // 256-bit identity hash confirmed
);

    // ── Parameters ─────────────────────────────────────────────────
    localparam [255:0] G1_IDENTITY  = 256'h8525D007_59A4_CA22_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000;
    localparam int      HASH_CYCLES = 64;          // 64 cycles × 4 bits = 256 bits

    // ── Internal signals ───────────────────────────────────────────
    wire [3:0] unit_valids;                        // causal-check results from 4 units
    logic      sbc_ready;                           // SBC handshake complete

    // ── Compute core signals ───────────────────────────────────────
    logic        comp_start;
    logic [2:0]  comp_op_mode;
    logic [63:0] comp_op_a, comp_op_b, comp_ts;
    logic        comp_done;
    logic [255:0] comp_p, comp_q;
    logic [63:0]  comp_result;

    // ── Identity verification state ────────────────────────────────
    logic [5:0]   hash_idx;                         // 0..63, which nibble we're on
    logic         hash_done;
    logic         hash_pass;
    logic [3:0]   expected_nibble;

    // ================================================================
    //  COMPUTE CORE  instantiation
    // ================================================================
    g1_compute_core u_compute (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (comp_start),
        .op_mode   (comp_op_mode),
        .operand_a (comp_op_a),
        .operand_b (comp_op_b),
        .timestamp (comp_ts),
        .done      (comp_done),
        .p_tag     (comp_p),
        .q_tag     (comp_q),
        .result    (comp_result)
    );

    // ================================================================
    //  SBC SEQUENCER  —  orchestrates compute → audit
    // ================================================================
    typedef enum logic [2:0] {
        SBC_IDLE      = 3'd0,
        SBC_COMPUTE   = 3'd1,
        SBC_WAIT_DONE = 3'd2,
        SBC_DISPATCH  = 3'd3,
        SBC_AUDIT     = 3'd4,
        SBC_STABLE    = 3'd5
    } sbc_state_t;

    sbc_state_t sbc_state, sbc_next;
    logic [3:0] sbc_cycle;                          // sub-cycle counter within AUDIT

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sbc_state    <= SBC_IDLE;
            sbc_cycle    <= 4'd0;
            comp_op_mode <= 3'd0;
            comp_op_a    <= 64'd0;
            comp_op_b    <= 64'd0;
            comp_ts      <= 64'd0;
        end else begin
            sbc_state <= sbc_next;
            if (sbc_state == SBC_IDLE && sbc_next == SBC_COMPUTE) begin
                // Latch operands on the IDLE→COMPUTE transition
                comp_op_mode <= internal_logic_stream[319:317];
                comp_op_a    <= internal_logic_stream[255:128];
                comp_op_b    <= internal_logic_stream[127:0];
                comp_ts      <= {32'd0, internal_logic_stream[319:288]};
            end
            if (sbc_state == SBC_AUDIT)
                sbc_cycle <= sbc_cycle + 1;
            else
                sbc_cycle <= 4'd0;
        end
    end

    always @(*) begin
        sbc_next   = sbc_state;
        comp_start = 1'b0;

        case (sbc_state)
            SBC_IDLE: begin
                // Start compute on ra_bus_valid with addr bit [2] set
                if (ra_bus_valid && ra_bus_addr[2]) begin
                    comp_start = 1'b1;
                    sbc_next   = SBC_COMPUTE;
                end
            end
            SBC_COMPUTE:   sbc_next = SBC_WAIT_DONE;
            SBC_WAIT_DONE: if (comp_done) sbc_next = SBC_DISPATCH;
            SBC_DISPATCH:  sbc_next = SBC_AUDIT;
            SBC_AUDIT:     if (sbc_cycle >= 4'd10) sbc_next = SBC_STABLE;
            SBC_STABLE:    if (!ra_bus_valid) sbc_next = SBC_IDLE;
            default:       sbc_next = SBC_IDLE;
        endcase
    end

    assign sbc_ready = (sbc_state == SBC_STABLE);

    // ================================================================
    //  CAUSAL AUDIT ARRAY  (4× parallel units)
    //  Each unit receives the same P/Q pair and verifies independently.
    // ================================================================
    logic dispatch_valid;
    assign dispatch_valid = (sbc_state == SBC_DISPATCH);

    generate
        genvar i;
        for (i = 0; i < 4; i = i + 1) begin : g1_audit_array
            spl_cim_causal_unit u_causal (
                .clk        (clk),
                .rst_n      (rst_n),
                .wr_en      (dispatch_valid),
                .wr_data_p  (comp_p),
                .wr_data_q  (comp_q),
                .logic_valid(unit_valids[i])
            );
        end
    endgenerate

    // ── PIM stability: all units passed + SBC ready ─────────────────
    assign pim_state_stable = (&unit_valids) && sbc_ready;

    // ================================================================
    //  HARDWARE IDENTITY ANCHOR  —  multi-cycle hash verification
    // ================================================================
    // The external system must present the 256-bit identity in 64 consecutive
    // nibbles (4-bit chunks).  A single mismatch permanently fails verification
    // until next reset.
    //
    // This is still stored as a constant in the netlist (not crypto-grade),
    // but requires a 64-cycle protocol rather than a single-wire match.

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hash_idx  <= 6'd0;
            hash_done <= 1'b0;
            hash_pass <= 1'b1;                      // assume pass until proven fail
        end else if (!hash_done) begin
            if (ra_bus_valid && ra_bus_addr[3]) begin  // addr bit [3] = hash strobe
                expected_nibble = G1_IDENTITY[(hash_idx * 4) +: 4];
                if (hardware_hash_in[3:0] != expected_nibble)
                    hash_pass <= 1'b0;              // permanent fail until reset
                hash_idx <= hash_idx + 1;
                if (hash_idx == 6'd63)
                    hash_done <= 1'b1;
            end
        end
    end

    assign logic_integrity_verified = hash_done && hash_pass;

endmodule
