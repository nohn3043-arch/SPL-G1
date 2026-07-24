// ============================================================================
// G1_Top_Integrated_v3 — SPL-G1 Full Integrated Top (v3.0, Phase A)
// ============================================================================
// Integrates all components:
//   1. RA-BUS Arbiter           — unified address plane (4 targets)
//   2. PIM Compute Array v2     — spl_pim_compute_array_v2 (parameterized, Cell v2)
//   3. PIM Sequencer v4         — spl_pim_sequencer (v4: control-flow + 256-entry prog mem)
//   4. Causal Audit Array v2    — spl_cim_causal_unit_v2 × 4 (constraint check)
//   5. Identity Anchor          — 256-bit hash verification
//   6. SBC Fuse                 — audit failure → permanent lock (Materica #4)
//
// v3 additions over v2:
//   - Sequencer v4: JMP/JZ/JNZ/CALL/RET control-flow, pim_flag feedback
//   - SBC fuse: fuse_blown output, audit_fb_pass==0 → latch → outputs zeroed
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module G1_Top_Integrated (
    input  logic         clk,
    input  logic         rst_n,

    // RA-BUS external host
    input  logic         ra_valid,
    input  logic [ 1:0]  ra_cmd,
    input  logic [31:0]  ra_addr,
    input  logic [63:0]  ra_wdata,
    output logic [63:0]  ra_rdata,
    output logic         ra_ready,
    output logic [ 1:0]  ra_resp,

    // Identity verification
    input  logic [255:0] hardware_hash_in,

    // Status
    output logic         pim_state_stable,
    output logic         logic_integrity_verified,

    // SBC fuse (Materica #4)
    output logic         fuse_blown       // v3: audit failure → permanent lock
);

    localparam [255:0] G1_IDENTITY  = 256'h8525D007_59A4_CA22_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000;
    localparam int      HASH_CYCLES = 64;
    localparam int      PIM_ROWS    = 4;
    localparam int      PIM_COLS    = 4;

    // ═══════════════════════════════════════════════
    // RA-BUS Arbiter → Target signals
    // ═══════════════════════════════════════════════
    logic        pim_bus_valid, audit_bus_valid, id_bus_valid, ext_bus_valid;
    logic [1:0]  pim_bus_cmd,   audit_bus_cmd,   id_bus_cmd,   ext_bus_cmd;
    logic [27:0] pim_bus_addr,  audit_bus_addr,  id_bus_addr,  ext_bus_addr;
    logic [63:0] pim_bus_wdata, audit_bus_wdata, id_bus_wdata, ext_bus_wdata;
    logic        pim_bus_store;
    logic [63:0] pim_bus_rdata, audit_bus_rdata, id_bus_rdata, ext_bus_rdata;
    logic        pim_bus_ready, audit_bus_ready, id_bus_ready, ext_bus_ready;
    logic [1:0]  pim_bus_resp,  audit_bus_resp,  id_bus_resp,  ext_bus_resp;

    // Internal RA-BUS readback (before fuse override)
    wire [63:0] ra_rdata_int;

    ra_bus_arbiter u_arbiter (
        .clk, .rst_n,
        .ra_valid, .ra_cmd, .ra_addr, .ra_wdata,
        .ra_rdata(ra_rdata_int), .ra_ready, .ra_resp,
        .pim_valid(pim_bus_valid), .pim_cmd(pim_bus_cmd), .pim_addr(pim_bus_addr),
        .pim_wdata(pim_bus_wdata), .pim_store(pim_bus_store),
        .pim_rdata(pim_bus_rdata), .pim_ready(pim_bus_ready), .pim_resp(pim_bus_resp),
        .audit_valid(audit_bus_valid), .audit_cmd(audit_bus_cmd), .audit_addr(audit_bus_addr),
        .audit_wdata(audit_bus_wdata),
        .audit_rdata(audit_bus_rdata), .audit_ready(audit_bus_ready), .audit_resp(audit_bus_resp),
        .id_valid(id_bus_valid), .id_cmd(id_bus_cmd), .id_addr(id_bus_addr),
        .id_wdata(id_bus_wdata),
        .id_rdata(id_bus_rdata), .id_ready(id_bus_ready), .id_resp(id_bus_resp),
        .ext_valid(ext_bus_valid), .ext_cmd(ext_bus_cmd), .ext_addr(ext_bus_addr),
        .ext_wdata(ext_bus_wdata),
        .ext_rdata(ext_bus_rdata), .ext_ready(ext_bus_ready), .ext_resp(ext_bus_resp)
    );

    // ═══════════════════════════════════════════════
    // PIM Sequencer v4 (v4: control-flow + pim_flag feedback)
    // ═══════════════════════════════════════════════
    logic        seq_busy, seq_done, seq_error;
    logic        pim_en, seq_audit_dispatch;
    logic [31:0] pim_seq_addr;
    logic [63:0] pim_seq_wdata;
    logic [ 7:0] pim_seq_op;
    logic [ 1:0] exec_mode;
    logic [ 7:0] seq_p_tag, seq_q_tag;
    logic        pim_flag_wire;   // v4: PIM→sequencer zero-flag

    spl_pim_sequencer u_sequencer (
        .clk, .rst_n,
        .ra_cmd_valid(pim_bus_valid),
        .ra_cmd(pim_bus_cmd),
        .ra_addr({4'd0, pim_bus_addr}),
        .ra_wdata(pim_bus_wdata),
        .audit_done(audit_fb_done),
        .audit_pass(audit_fb_pass),
        .pim_flag(pim_flag_wire),
        .seq_busy, .seq_done, .seq_error,
        .pim_en,
        .pim_addr(pim_seq_addr),
        .pim_wdata(pim_seq_wdata),
        .pim_op(pim_seq_op),
        .exec_mode,
        .audit_dispatch(seq_audit_dispatch),
        .gen_p_tag(seq_p_tag),
        .gen_q_tag(seq_q_tag)
    );

    // ═══════════════════════════════════════════════
    // PIM Compute Array v2 (cell_v2 + parameterized + 8-bit neighbour)
    // ═══════════════════════════════════════════════
    logic [63:0] pim_array_rdata;
    logic        pim_array_ready;
    logic [1:0]  pim_array_resp;
    logic [ 7:0] pim_p_tags [PIM_ROWS-1:0][PIM_COLS-1:0];
    logic [ 7:0] pim_q_tags [PIM_ROWS-1:0][PIM_COLS-1:0];
    logic [63:0] pim_vec_sum [PIM_COLS-1:0];
    logic [63:0] pim_mat_total;

    spl_pim_compute_array #(.ROWS(PIM_ROWS), .COLS(PIM_COLS)) u_pim_array (
        .ra_clk(clk), .ra_rst_n(rst_n),
        .ra_en(pim_en),
        .ra_addr(pim_seq_addr),
        .ra_wdata(pim_seq_wdata),
        .ra_rdata(pim_array_rdata),
        .pim_op(pim_seq_op),
        .pim_store_en(pim_bus_store && pim_en),
        .exec_mode,
        .raw_p_tag(pim_p_tags),
        .raw_q_tag(pim_q_tags),
        .pim_ready(pim_array_ready),
        .pim_resp(pim_array_resp),
        .vec_sum(pim_vec_sum),
        .mat_total(pim_mat_total),
        .pim_flag(pim_flag_wire)
    );

    assign pim_bus_rdata = pim_array_rdata;
    assign pim_bus_ready = seq_done;
    assign pim_bus_resp  = seq_error ? 2'd1 : 2'd0;

    // ═══════════════════════════════════════════════
    // Causal Audit Array v2 (NOMOS constraint + dep_mask cascade)
    // ═══════════════════════════════════════════════
    logic [3:0] unit_valids;
    logic       dispatch_valid;
    logic [3:0] check_dones, check_passes;       // v3: per-check handshake
    logic       audit_fb_done, audit_fb_pass;    // v3: AND-reduced feedback to sequencer
    logic [255:0] audit_p, audit_q;

    // Aggregate P→Q tags from PIM array into audit pipeline
    // Format for v2: exact 256-bit field-aligned causal_record
    //   [255:248] rule_id         = 8'h00 (bridge mode)
    //   [247:192] dep_mask        = 56-bit packed P-tag fingerprint
    //   [191:128] constraint_bits = 64'hFFFF_FFFF_FFFF_FFFF (all pass)
    //   [127:64]  weight_q16_16   = 64'h0 (bridge)
    //   [63:0]    unused
    wire [55:0] dep_mask_bits;   // 56-bit exactly for [247:192]
    assign dep_mask_bits = {
        9'h0,                       // pad to 56 bits
        pim_p_tags[0][0][5:0],      // 6 bits
        pim_p_tags[0][1][5:0],      // 6 bits
        pim_p_tags[0][2][5:0],      // 6 bits
        pim_p_tags[0][3][5:0],      // 6 bits
        pim_p_tags[1][0][5:0],      // 6 bits
        pim_p_tags[1][1][5:0],      // 6 bits
        pim_p_tags[1][2][5:0],      // 6 bits
        pim_p_tags[1][3][4:0]       // 5 bits  → total 9+47 = 56
    };

    assign audit_p = {
        8'h00,                          // rule_id          [255:248]
        dep_mask_bits,                  // dep_mask         [247:192]
        64'hFFFF_FFFF_FFFF_FFFF,        // constraint_bits  [191:128]
        64'h0,                          // weight_q16_16    [127:64]
        64'h0                           // pad              [63:0]
    };  // 8 + 56 + 64 + 64 + 64 = 256

    assign audit_q = {
        192'h0,
        pim_q_tags[0][0], pim_q_tags[0][1], pim_q_tags[0][2], pim_q_tags[0][3],
        pim_q_tags[1][0], pim_q_tags[1][1], pim_q_tags[1][2], pim_q_tags[1][3]
    };

    assign dispatch_valid = seq_audit_dispatch;   // v3: per-op dispatch, not batch seq_done

    generate
        genvar gi;
        for (gi = 0; gi < 4; gi = gi + 1) begin : g1_audit
            spl_cim_causal_unit u_causal (
                .clk, .rst_n,
                .wr_en(dispatch_valid),
                .wr_data_p(audit_p),
                .wr_data_q(audit_q),
                .logic_valid(unit_valids[gi]),
                .check_done(check_dones[gi]),
                .check_pass(check_passes[gi])
            );
        end
    endgenerate

    // ── Causal audit feedback to sequencer (v3: closed loop) ──
    assign audit_fb_done = (&check_dones);
    assign audit_fb_pass = (&check_passes);

    assign audit_bus_rdata = {60'h0, unit_valids};
    assign audit_bus_ready = 1'b1;
    assign audit_bus_resp  = 2'd0;

    // ═══════════════════════════════════════════════
    // Identity Anchor (unchanged)
    // ═══════════════════════════════════════════════
    logic [5:0]  hash_idx;
    logic        hash_done, hash_pass;
    logic [3:0]  expected_nibble;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hash_idx  <= 6'd0;
            hash_done <= 1'b0;
            hash_pass <= 1'b1;
        end else if (!hash_done) begin
            if (id_bus_valid && id_bus_cmd == 2'b01) begin
                expected_nibble = G1_IDENTITY[(hash_idx * 4) +: 4];
                if (hardware_hash_in[3:0] != expected_nibble)
                    hash_pass <= 1'b0;
                hash_idx <= hash_idx + 1;
                if (hash_idx == 6'd63)
                    hash_done <= 1'b1;
            end
        end
    end

    assign logic_integrity_verified = hash_done && hash_pass;
    assign id_bus_rdata  = {58'h0, hash_done, hash_pass, hash_idx};
    assign id_bus_ready  = 1'b1;
    assign id_bus_resp   = 2'd0;

    // ═══════════════════════════════════════════════
    // External expansion (target 3) — stub
    // ═══════════════════════════════════════════════
    assign ext_bus_rdata = 64'hDEAD_0000_0000_BEEF;
    assign ext_bus_ready = 1'b1;
    assign ext_bus_resp  = 2'd1;

    // ═══════════════════════════════════════════════
    // SBC Fuse — Materica #4 Security Boundary Controller
    // ═══════════════════════════════════════════════
    // Audit failure (audit_fb_done && !audit_fb_pass) → permanent logic lock.
    // Once blown, all RA-BUS output data is forced to 0.
    // Recovery: hardware reset (rst_n) only. Software/commands cannot clear.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fuse_blown <= 1'b0;
        end else if (audit_fb_done && !audit_fb_pass) begin
            fuse_blown <= 1'b1;   // audit violation → permanent lock
        end
    end

    // ═══════════════════════════════════════════════
    // Top-level status (fuse-aware)
    // ═══════════════════════════════════════════════
    assign pim_state_stable = (&unit_valids) && !seq_busy && !fuse_blown;

    // Fuse-blown output override: force rdata to zero
    assign ra_rdata = fuse_blown ? 64'h0 : ra_rdata_int;

endmodule
