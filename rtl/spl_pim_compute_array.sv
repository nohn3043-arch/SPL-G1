// ============================================================================
// spl_pim_compute_array_v2 — PIM Compute Grid v2 (Parameterized + Cell v2)
// ============================================================================
// Upgrades over v1:
//   - Cell: spl_pim_cell → spl_pim_cell_v2 (32-op + predicate + 8-bit neighbour)
//   - Neighbour: 1-bit → 8-bit wide interconnect
//   - Reduction: fully parameterized (ROWS×COLS auto-derived, not hardcoded 4)
//   - Predicate: pred_en wired in SCALAR mode only
//   - ra_op: 8-bit sequencer op → 5-bit cell op (truncated)
//
// Backward compatible port map with spl_pim_compute_array.
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_pim_compute_array #(
    parameter int ROWS = 4,
    parameter int COLS = 4
) (
    input  logic                  ra_clk,
    input  logic                  ra_rst_n,
    input  logic                  ra_en,
    input  logic [31:0]           ra_addr,
    input  logic [63:0]           ra_wdata,
    output logic [63:0]           ra_rdata,

    input  logic [ 7:0]           pim_op,
    input  logic                  pim_store_en,
    input  logic [ 1:0]           exec_mode,

    output logic [ 7:0]           raw_p_tag [ROWS-1:0][COLS-1:0],
    output logic [ 7:0]           raw_q_tag [ROWS-1:0][COLS-1:0],

    output logic                  pim_ready,
    output logic [ 1:0]           pim_resp,

    output logic [63:0]           vec_sum   [COLS-1:0],
    output logic [63:0]           mat_total,

    output logic                  pim_flag,    // v4: result-is-zero flag (latched, for control flow)

    // ── Materica compliance observation ports (v3.1) ──
    // PACKED vectors (iverilog-compatible across module boundaries):
    //   cell_state_obs_packed[ROWS*COLS*64-1:0]
    //   cell_op_obs_packed[ROWS*COLS*5-1:0]
    output logic [ROWS*COLS*64-1:0] cell_state_obs_packed,
    output logic [ROWS*COLS*5 -1:0] cell_op_obs_packed
);

    logic [63:0] cell_data_out [ROWS-1:0][COLS-1:0];
    logic [ 7:0] ns_link_in    [ROWS-1:0][COLS-1:0];
    logic [ 7:0] ns_link_out   [ROWS-1:0][COLS-1:0];
    logic [ 7:0] ew_link_in    [ROWS-1:0][COLS-1:0];
    logic [ 7:0] ew_link_out   [ROWS-1:0][COLS-1:0];
    logic [ 4:0] cell_op;

    assign cell_op = pim_op[4:0];

    // ── Row/col decode ──
    // Note: iverilog (vvp) does not support variable selects on unpacked
    // arrays in always_* processes. Use generate loops instead.
    logic [ROWS-1:0] row_sel;
    logic [COLS-1:0] col_sel;
    logic [7:0] sel_row_idx;
    logic [7:0] sel_col_idx;
    assign sel_row_idx = ra_addr[31:24];
    assign sel_col_idx = ra_addr[23:16];

    genvar dr, dc;
    generate
        for (dr = 0; dr < ROWS; dr = dr + 1) begin : gen_row_sel
            always_comb begin
                row_sel[dr] = 1'b0;
                if (ra_en) begin
                    case (exec_mode)
                        2'b01: if (dr == sel_row_idx) row_sel[dr] = 1'b1;
                        2'b10: row_sel[dr] = 1'b1;
                        2'b11: row_sel[dr] = 1'b1;
                        default: ;
                    endcase
                end
            end
        end
        for (dc = 0; dc < COLS; dc = dc + 1) begin : gen_col_sel
            always_comb begin
                col_sel[dc] = 1'b0;
                if (ra_en) begin
                    case (exec_mode)
                        2'b01: if (dc == sel_col_idx) col_sel[dc] = 1'b1;
                        2'b10: if (dc == sel_col_idx) col_sel[dc] = 1'b1;
                        2'b11: col_sel[dc] = 1'b1;
                        default: ;
                    endcase
                end
            end
        end
    endgenerate

    // ── Cell instantiation (v2) ──
    wire cell_pred_en = (exec_mode == 2'b01);

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_row
            for (c = 0; c < COLS; c = c + 1) begin : gen_col
                wire pred_o;
                spl_pim_cell #(.IDX_ROW(r), .IDX_COL(c)) u_cell (
                    .ra_clk, .ra_rst_n,
                    .ra_op        (cell_op),
                    .ra_data_in   (row_sel[r] && col_sel[c] ? ra_wdata : 64'h0),
                    .ra_data_out  (cell_data_out[r][c]),
                    .pim_store_en,
                    .row_data_in  (ns_link_in[r][c]),
                    .row_data_out (ns_link_out[r][c]),
                    .col_data_in  (ew_link_in[r][c]),
                    .col_data_out (ew_link_out[r][c]),
                    .pred_en      (cell_pred_en),
                    .pred_reg     (pred_o),
                    .exec_mode    (row_sel[r] && col_sel[c] ? exec_mode : 2'b00),
                    .p_tag_value  (raw_p_tag[r][c]),
                    .q_tag_value  (raw_q_tag[r][c])
                );
            end
        end
    endgenerate

    // ── Neighbour wiring (8-bit grid) ──
    generate
        for (c = 0; c < COLS; c = c + 1) begin : gen_ns
            assign ns_link_in[0][c] = 8'h00;
            for (r = 0; r < ROWS-1; r = r + 1) begin : gen_ns_int
                assign ns_link_in[r+1][c] = ns_link_out[r][c];
            end
        end
        for (r = 0; r < ROWS; r = r + 1) begin : gen_ew
            assign ew_link_in[r][0] = 8'h00;
            for (c = 0; c < COLS-1; c = c + 1) begin : gen_ew_int
                assign ew_link_in[r][c+1] = ew_link_out[r][c];
            end
        end
    endgenerate

    // ── SCALAR readback (generate-based, no variable select on arrays) ──
    logic [63:0] rd_cell [ROWS-1:0][COLS-1:0];
    genvar rr, rc;
    generate
        for (rr = 0; rr < ROWS; rr = rr + 1) begin : gen_rd_r
            for (rc = 0; rc < COLS; rc = rc + 1) begin : gen_rd_c
                assign rd_cell[rr][rc] = (ra_en && exec_mode == 2'b01 &&
                                          rr == sel_row_idx && rc == sel_col_idx)
                                         ? cell_data_out[rr][rc] : 64'h0;
            end
        end
    endgenerate
    always_comb begin
        ra_rdata = 64'h0;
        for (integer rdi = 0; rdi < ROWS; rdi = rdi + 1)
            for (integer rdj = 0; rdj < COLS; rdj = rdj + 1)
                ra_rdata = ra_rdata | rd_cell[rdi][rdj];
    end

    // ── Parameterized vector sum (per column) ──
    generate
        for (c = 0; c < COLS; c = c + 1) begin : gen_vec_sum
            logic [63:0] col_acc;
            integer ri;
            always_comb begin
                col_acc = 64'd0;
                for (ri = 0; ri < ROWS; ri = ri + 1)
                    col_acc = col_acc + cell_data_out[ri][c];
            end
            assign vec_sum[c] = col_acc;
        end
    endgenerate

    // ── Parameterized matrix total ──
    integer mr, mc;
    always_comb begin
        mat_total = 64'd0;
        for (mr = 0; mr < ROWS; mr = mr + 1)
            for (mc = 0; mc < COLS; mc = mc + 1)
                mat_total = mat_total + cell_data_out[mr][mc];
    end

    // ── Ready / Response ──
    logic ra_en_d1;
    always_ff @(posedge ra_clk or negedge ra_rst_n) begin
        if (!ra_rst_n) ra_en_d1 <= 1'b0; else ra_en_d1 <= ra_en;
    end
    assign pim_ready = ra_en_d1;
    assign pim_resp  = 2'd0;

    // ── Materica observation fan-out (packed) ──
    genvar mo_r, mo_c;
    generate
        for (mo_r = 0; mo_r < ROWS; mo_r = mo_r + 1) begin : gen_mat_obs_r
            for (mo_c = 0; mo_c < COLS; mo_c = mo_c + 1) begin : gen_mat_obs_c
                assign cell_state_obs_packed[((mo_r*COLS+mo_c)+1)*64-1 -: 64] = cell_data_out[mo_r][mo_c];
                assign cell_op_obs_packed[((mo_r*COLS+mo_c)+1)*5 -1 -: 5]    = cell_op;
            end
        end
    endgenerate

    // ── pim_flag: latched result-is-zero for control-flow branching ──
    // Uses generate-based scalar readback (rd_cell) to avoid variable
    // selects on unpacked arrays (iverilog limitation).
    logic [63:0] flag_cell_val;
    always_comb begin
        flag_cell_val = 64'h0;
        for (integer fdi = 0; fdi < ROWS; fdi = fdi + 1)
            for (integer fdj = 0; fdj < COLS; fdj = fdj + 1)
                flag_cell_val = flag_cell_val | rd_cell[fdi][fdj];
    end

    always_ff @(posedge ra_clk or negedge ra_rst_n) begin
        if (!ra_rst_n) begin
            pim_flag <= 1'b0;
        end else begin
            unique case (exec_mode)
                2'b01:   pim_flag <= (flag_cell_val == 64'd0);
                2'b10:   pim_flag <= (vec_sum[sel_col_idx] == 64'd0);
                2'b11:   pim_flag <= (mat_total == 64'd0);
                default: pim_flag <= 1'b0;
            endcase
        end
    end

endmodule
