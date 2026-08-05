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

module G1_Top_Integrated #(
    parameter int DATA_W = 128        // v3: RA-BUS data width (64=legacy, 128=expanded)
) (
    input  logic         clk,
    input  logic         rst_n,

    // RA-BUS external host
    input  logic         ra_valid,
    input  logic [ 1:0]  ra_cmd,
    input  logic [31:0]  ra_addr,
    input  logic [DATA_W-1:0] ra_wdata,
    output logic [DATA_W-1:0] ra_rdata,
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
    localparam int      PIM_ROWS    = 64;   // v6: Phase B — commercial scale (4,096 units)
    localparam int      PIM_COLS    = 64;   // v6: Phase B — commercial scale (4,096 units)

    // ═══════════════════════════════════════════════
    // RA-BUS Arbiter → Target signals
    // ═══════════════════════════════════════════════
    logic        pim_bus_valid, audit_bus_valid, id_bus_valid, ext_bus_valid;
    logic [1:0]  pim_bus_cmd,   audit_bus_cmd,   id_bus_cmd,   ext_bus_cmd;
    logic [27:0] pim_bus_addr,  audit_bus_addr,  id_bus_addr,  ext_bus_addr;
    logic [DATA_W-1:0] pim_bus_wdata, audit_bus_wdata, id_bus_wdata, ext_bus_wdata;
    logic        pim_bus_store;
    logic [DATA_W-1:0] pim_bus_rdata, audit_bus_rdata, id_bus_rdata, ext_bus_rdata;
    logic        pim_bus_ready, audit_bus_ready, id_bus_ready, ext_bus_ready;
    logic [1:0]  pim_bus_resp,  audit_bus_resp,  id_bus_resp,  ext_bus_resp;

    // Internal RA-BUS readback (before fuse override)
    wire [DATA_W-1:0] ra_rdata_int;

    ra_bus_arbiter #(.DATA_W(DATA_W)) u_arbiter (
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
    logic [DATA_W-1:0] pim_seq_wdata;
    logic [ 7:0] pim_seq_op;
    logic [ 1:0] exec_mode;
    logic [ 7:0] seq_p_tag, seq_q_tag;
    logic        pim_flag_wire;   // v4: PIM→sequencer zero-flag

    spl_pim_sequencer #(.PROG_DEPTH(1024), .DATA_W(DATA_W)) u_sequencer (
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
    logic [DATA_W-1:0] pim_array_rdata;
    logic        pim_array_ready;
    logic [1:0]  pim_array_resp;
    logic [ 7:0] pim_p_tags [PIM_ROWS-1:0][PIM_COLS-1:0];
    logic [ 7:0] pim_q_tags [PIM_ROWS-1:0][PIM_COLS-1:0];
    logic [DATA_W-1:0] pim_vec_sum [PIM_COLS-1:0];
    logic [DATA_W-1:0] pim_mat_total;

    spl_pim_compute_array #(.ROWS(PIM_ROWS), .COLS(PIM_COLS), .DATA_W(DATA_W)) u_pim_array (
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
        .pim_flag(pim_flag_wire),
        .cell_state_obs_packed(),   // materica unit instantiated at testbench level
        .cell_op_obs_packed()
    );

    assign pim_bus_rdata = fuse_blown ? {DATA_W{1'b0}} : pim_array_rdata;
    assign pim_bus_ready = seq_done;
    assign pim_bus_resp  = seq_error ? 2'd1 : 2'd0;

    // ═══════════════════════════════════════════════
    // Causal Audit Array v2 (constraint check + dep_mask cascade)
    // ═══════════════════════════════════════════════
    logic [3:0] unit_valids;
    logic       dispatch_valid;
    logic [3:0] check_dones, check_passes;
    logic       audit_fb_done, audit_fb_pass;
    logic [255:0] audit_p, audit_q;

    // ═══════════════════════════════════════════════
    // A5: Causal Constraint Rules v1
    // ═══════════════════════════════════════════════
    // audit_constraint_mask: 64-bit configurable constraint gate.
    //   bit[0]: allow integer ALU  (ADD/SUB/MUL/CMP/SHIFT/LOGIC/NOP)
    //   bit[1]: allow FP16 ops     (FP16_ADD/SUB/MUL/CMP/MAC)
    //   bit[2]: allow VECTOR mode
    //   bit[3]: allow MATRIX mode
    //   bits[63:4]: reserved (always 1)
    //   Default = all-1s (bridge mode, backward-compatible).
    //   Program via CONFIG command with ra_addr[27:24] = 4'b0101 (constraint cfg).
    logic [63:0] audit_constraint_mask;   // 1=allowed, 0=forbidden

    // Per-op constraint_bits: gate based on opcode class
    // Latched at dispatch time: audit unit samples S_CHECK one+ cycles after
    // dispatch, when sequencer may have left SEQ_EXEC (pim_op resets to 0).
    // Latching avoids the audit seeing all-1s by the time it evaluates.
    logic [63:0] constraint_bits_op;
    logic [63:0] constraint_bits_latch;
    wire is_fp16_op  = (pim_seq_op[4:0] >= 5'h13) && (pim_seq_op[4:0] <= 5'h17);
    wire is_mat_mode = (exec_mode == 2'b11);
    wire is_vec_mode = (exec_mode == 2'b10);

    assign constraint_bits_op = {
        60'hFFFF_FFFF_FFFFFFF,
        audit_constraint_mask[3] || !is_mat_mode,       // bit[3]: MATRIX gate
        audit_constraint_mask[2] || !is_vec_mode,       // bit[2]: VECTOR gate
        audit_constraint_mask[1] || !is_fp16_op,        // bit[1]: FP16 gate
        audit_constraint_mask[0]                        // bit[0]: integer ALU gate
    };

    // Latch at dispatch pulse (seq_audit_dispatch)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            constraint_bits_latch <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else if (seq_audit_dispatch) begin
            constraint_bits_latch <= constraint_bits_op;
        end
    end

    // Aggregate P→Q tags from PIM array into audit pipeline
    // Format for v2: exact 256-bit field-aligned causal_record
    //   [255:248] rule_id         = 8'h00 (bridge mode)
    //   [247:192] dep_mask        = 56-bit packed P-tag fingerprint
    //   [191:128] constraint_bits = 64'hFFFF_FFFF_FFFF_FFFF (all pass)
    //   [127:64]  weight_q16_16   = 64'h0 (bridge)
    //   [63:0]    unused
    //
    // v3 (16x16): 256 cells can't fit in 56-bit dep_mask.
    // Quadrant-aggregation: each of the 4 audit units covers one 8x8
    // quadrant; within a quadrant, 64 cells' P-tags are XOR-folded into
    // a 14-bit fingerprint (56/4). Lossy aggregation — full 256-bit
    // dep_mask deferred to Phase A5 (NOMOS constraint rules).
    genvar qr, qc;
    logic [13:0] quad_dep [0:3];
    generate
        for (qr = 0; qr < 2; qr = qr + 1) begin : gen_quad_r
            for (qc = 0; qc < 2; qc = qc + 1) begin : gen_quad_c
                logic [13:0] quad_acc;
                integer qi, qj;
                always_comb begin
                    quad_acc = 14'd0;
                    for (qi = 0; qi < PIM_ROWS/2; qi = qi + 1)
                        for (qj = 0; qj < PIM_COLS/2; qj = qj + 1)
                            quad_acc = quad_acc ^ pim_p_tags[qr*(PIM_ROWS/2)+qi][qc*(PIM_COLS/2)+qj][5:0];
                end
                assign quad_dep[qr*2+qc] = quad_acc;
            end
        end
    endgenerate

    wire [55:0] dep_mask_bits;   // 56-bit exactly for [247:192]
    assign dep_mask_bits = { quad_dep[0], quad_dep[1], quad_dep[2], quad_dep[3] };

    assign audit_p = {
        8'h00,                          // rule_id          [255:248]
        dep_mask_bits,                  // dep_mask         [247:192]
        constraint_bits_latch,          // constraint_bits  [191:128] — A5: latched at dispatch
        64'h0,                          // weight_q16_16    [127:64]
        64'h0                           // pad              [63:0]
    };  // 8 + 56 + 64 + 64 + 64 = 256

    assign audit_q = {
        192'h0,
        quad_dep[0], quad_dep[1], quad_dep[2], quad_dep[3]
    };  // 192 + 56 = 248 ≤ 256

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
    // External Memory Controller (target 3) — 16MB SRAM + DMA + AXI4
    // ═══════════════════════════════════════════════
    ext_mem_controller #(.DATA_W(DATA_W)) u_ext_mem (
        .clk, .rst_n,
        .ra_valid(ext_bus_valid), .ra_cmd(ext_bus_cmd), .ra_addr(ext_bus_addr),
        .ra_wdata(ext_bus_wdata), .ra_rdata(ext_bus_rdata),
        .ra_ready(ext_bus_ready), .ra_resp(ext_bus_resp),
        // AXI4 master interface (tied off for simulation; connect to PHY in synthesis)
        .axi_awvalid(), .axi_awready(1'b0), .axi_awaddr(), .axi_awlen(),
        .axi_awsize(), .axi_awburst(), .axi_awid(),
        .axi_wvalid(), .axi_wready(1'b0), .axi_wdata(), .axi_wstrb(), .axi_wlast(),
        .axi_bvalid(1'b0), .axi_bready(), .axi_bresp(2'd0), .axi_bid('0),
        .axi_arvalid(), .axi_arready(1'b0), .axi_araddr(), .axi_arlen(),
        .axi_arsize(), .axi_arburst(), .axi_arid(),
        .axi_rvalid(1'b0), .axi_rready(), .axi_rdata('0), .axi_rresp(2'd0),
        .axi_rlast(1'b0), .axi_rid('0),
        .dma_busy(), .dma_done()
    );

    // ═══════════════════════════════════════════════
    // SBC Fuse — Materica #4 Security Boundary Controller
    // ═══════════════════════════════════════════════
    // Audit failure → permanent output data path cut (PIM target only).
    // Internal logic, audit pipeline, identity anchor remain fully intact.
    // Audit logs / status / identity are readable even after fuse blown.
    // Recovery: hardware reset (rst_n) only.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fuse_blown <= 1'b0;
        end else if (audit_fb_done && !audit_fb_pass) begin
            fuse_blown <= 1'b1;   // audit violation → cut output data path
            `ifdef SIMULATION
            $display("[FUSE] blown: fb_done=%b fb_pass=%b", audit_fb_done, audit_fb_pass);
            `endif
        end
    end

    // ═══════════════════════════════════════════════
    // A5: Constraint Mask — Programmable class gate (Materica #1 chain)
    // ═══════════════════════════════════════════════
    // 64-bit: bit[i]=1 → operation class i is ALLOWED.
    // Program via CONFIG on audit target with addr[27:24]=4'b0101.
    // Default = all-1s (bridge mode, backward-compatible).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audit_constraint_mask <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else if (audit_bus_valid && audit_bus_cmd == 2'b11
                     && audit_bus_addr[27:24] == 4'b0101) begin
            audit_constraint_mask <= audit_bus_wdata;
        end
    end

    // ═══════════════════════════════════════════════
    // Top-level status (fuse-aware)
    // ═══════════════════════════════════════════════
    // fuse_blown cuts only PIM-data output; audit/identity remain readable.
    // pim_state_stable goes 0 when fuse is blown (output data path is cut).
    assign pim_state_stable = (&unit_valids) && !seq_busy && !fuse_blown;

    // ra_rdata: arbiter routes target → no override needed (per-target gated above)
    assign ra_rdata = ra_rdata_int;

endmodule
