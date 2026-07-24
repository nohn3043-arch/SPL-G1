// ============================================================================
// G1_Top_Integrated — SPL-G1 Full Integrated Top (v1.0)
// ============================================================================
// Integrates:
//   1. RA-BUS Arbiter           — unified address plane (4 targets)
//   2. PIM Compute Array (4×4)  — SCALAR/VECTOR/MATRIX compute
//   3. PIM Sequencer            — micro-op instruction table
//   4. Causal Audit Array (×4)  — hardware audit pipeline
//   5. Identity Anchor          — 256-bit hash verification
//   6. SBC Sequencer            — orchestrates compute→audit flow
//
// This replaces the original G1_Top_Interface.v by re-wiring g1_compute_core
// with the full PIM compute array + RA-BUS arbiter fabric.
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module G1_Top_Integrated (
    input  logic         clk,
    input  logic         rst_n,

    // ── RA-BUS external host ──
    input  logic         ra_valid,
    input  logic [ 1:0]  ra_cmd,
    input  logic [31:0]  ra_addr,
    input  logic [63:0]  ra_wdata,
    output logic [63:0]  ra_rdata,
    output logic         ra_ready,
    output logic [ 1:0]  ra_resp,

    // ── Identity verification nibble ──
    input  logic [255:0] hardware_hash_in,

    // ── Status outputs ──
    output logic         pim_state_stable,
    output logic         logic_integrity_verified
);

    // ── Identity constants ──
    localparam [255:0] G1_IDENTITY  = 256'h8525D007_59A4_CA22_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000;
    localparam int      HASH_CYCLES = 64;

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

    ra_bus_arbiter u_arbiter (
        .clk, .rst_n,
        .ra_valid, .ra_cmd, .ra_addr, .ra_wdata,
        .ra_rdata, .ra_ready, .ra_resp,
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
    // PIM Sequencer (target 0)
    // ═══════════════════════════════════════════════
    logic        seq_busy, seq_done, seq_error;
    logic        pim_en;
    logic [31:0] pim_seq_addr;
    logic [63:0] pim_seq_wdata;
    logic [ 7:0] pim_seq_op;
    logic [ 1:0] exec_mode;
    logic [ 7:0] seq_p_tag, seq_q_tag;

    spl_pim_sequencer u_sequencer (
        .clk, .rst_n,
        .ra_cmd_valid(pim_bus_valid),
        .ra_cmd(pim_bus_cmd),
        .ra_addr({4'd0, pim_bus_addr}),
        .ra_wdata(pim_bus_wdata),
        .seq_busy, .seq_done, .seq_error,
        .pim_en,
        .pim_addr(pim_seq_addr),
        .pim_wdata(pim_seq_wdata),
        .pim_op(pim_seq_op),
        .exec_mode,
        .gen_p_tag(seq_p_tag),
        .gen_q_tag(seq_q_tag)
    );

    // ═══════════════════════════════════════════════
    // PIM Compute Array (4×4)
    // ═══════════════════════════════════════════════
    logic [63:0] pim_array_rdata;
    logic        pim_array_ready;
    logic [1:0]  pim_array_resp;
    logic [ 7:0] pim_p_tags [3:0][3:0];
    logic [ 7:0] pim_q_tags [3:0][3:0];
    logic [63:0] pim_vec_sum [3:0];
    logic [63:0] pim_mat_total;

    spl_pim_compute_array #(.ROWS(4), .COLS(4)) u_pim_array (
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
        .mat_total(pim_mat_total)
    );

    assign pim_bus_rdata = pim_array_rdata;
    assign pim_bus_ready = seq_done;     // ready when sequence complete
    assign pim_bus_resp  = seq_error ? 2'd1 : 2'd0;

    // ═══════════════════════════════════════════════
    // Causal Audit Array (target 1)
    // ═══════════════════════════════════════════════
    logic [3:0] unit_valids;
    logic       dispatch_valid;
    logic [255:0] audit_p, audit_q;

    // Aggregate P→Q from PIM array into audit pipeline
    assign audit_p = {pim_p_tags[0][0], pim_p_tags[0][1], pim_p_tags[0][2], pim_p_tags[0][3],
                      pim_p_tags[1][0], pim_p_tags[1][1], pim_p_tags[1][2], pim_p_tags[1][3],
                      pim_p_tags[2][0], pim_p_tags[2][1], pim_p_tags[2][2], pim_p_tags[2][3],
                      pim_p_tags[3][0], pim_p_tags[3][1], pim_p_tags[3][2], pim_p_tags[3][3],
                      // upper 128 zero
                      128'h0};
    assign audit_q = {pim_q_tags[0][0], pim_q_tags[0][1], pim_q_tags[0][2], pim_q_tags[0][3],
                      pim_q_tags[1][0], pim_q_tags[1][1], pim_q_tags[1][2], pim_q_tags[1][3],
                      pim_q_tags[2][0], pim_q_tags[2][1], pim_q_tags[2][2], pim_q_tags[2][3],
                      pim_q_tags[3][0], pim_q_tags[3][1], pim_q_tags[3][2], pim_q_tags[3][3],
                      128'h0};

    assign dispatch_valid = seq_done;

    generate
        genvar gi;
        for (gi = 0; gi < 4; gi = gi + 1) begin : g1_audit
            spl_cim_causal_unit u_causal (
                .clk, .rst_n,
                .wr_en(dispatch_valid),
                .wr_data_p(audit_p),
                .wr_data_q(audit_q),
                .logic_valid(unit_valids[gi])
            );
        end
    endgenerate

    // Audit bus (read-only: expose unit_valids)
    assign audit_bus_rdata = {60'h0, unit_valids};
    assign audit_bus_ready = 1'b1;
    assign audit_bus_resp  = 2'd0;

    // ═══════════════════════════════════════════════
    // Identity Anchor (target 2)
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
            if (id_bus_valid && id_bus_cmd == 2'b01) begin  // WRITE = hash nibble
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
    assign ext_bus_rdata = 64'hDEAD_0000_0000_BEEF;  // reserved
    assign ext_bus_ready = 1'b1;
    assign ext_bus_resp  = 2'd1;   // not implemented

    // ═══════════════════════════════════════════════
    // Top-level status
    // ═══════════════════════════════════════════════
    assign pim_state_stable = (&unit_valids) && !seq_busy;

endmodule
