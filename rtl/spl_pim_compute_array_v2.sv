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

module spl_pim_compute_array_v2 #(
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
    output logic [63:0]           mat_total
);

    logic [63:0] cell_data_out [ROWS-1:0][COLS-1:0];
    logic [ 7:0] ns_link_in    [ROWS-1:0][COLS-1:0];
    logic [ 7:0] ns_link_out   [ROWS-1:0][COLS-1:0];
    logic [ 7:0] ew_link_in    [ROWS-1:0][COLS-1:0];
    logic [ 7:0] ew_link_out   [ROWS-1:0][COLS-1:0];
    logic [ 4:0] cell_op;

    assign cell_op = pim_op[4:0];

    // ── Row/col decode ──
    logic [ROWS-1:0] row_sel;
    logic [COLS-1:0] col_sel;

    always_comb begin
        row_sel = {ROWS{1'b0}};
        col_sel = {COLS{1'b0}};
        if (ra_en) begin
            case (exec_mode)
                2'b01: begin row_sel[ra_addr[31:24]] = 1'b1; col_sel[ra_addr[23:16]] = 1'b1; end
                2'b10: begin row_sel = {ROWS{1'b1}};        col_sel[ra_addr[23:16]] = 1'b1; end
                2'b11: begin row_sel = {ROWS{1'b1}};        col_sel = {COLS{1'b1}};        end
                default: ;
            endcase
        end
    end

    // ── Cell instantiation (v2) ──
    wire cell_pred_en = (exec_mode == 2'b01);

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_row
            for (c = 0; c < COLS; c = c + 1) begin : gen_col
                wire pred_o;
                spl_pim_cell_v2 #(.IDX_ROW(r), .IDX_COL(c)) u_cell (
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

    // ── SCALAR readback ──
    always_comb begin
        ra_rdata = 64'h0;
        if (ra_en && exec_mode == 2'b01)
            ra_rdata = cell_data_out[ra_addr[31:24]][ra_addr[23:16]];
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

endmodule
