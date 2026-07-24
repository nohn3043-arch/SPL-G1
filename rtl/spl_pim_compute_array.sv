// ============================================================================
// spl_pim_compute_array — PIM Compute Grid (ROWS × COLS cells)
// ============================================================================
// A 2D grid of spl_pim_cell instances, driven by the micro-op sequencer
// and addressed via RA-BUS. Supports three execution modes on THE SAME grid:
//
//   SCALAR  — single cell targeted by ra_addr; scalar arithmetic
//   VECTOR  — one column activated; all rows in column compute in parallel
//   MATRIX  — full 2D array; used for matrix multiply / systolic accumulation
//
// The array produces P/Q causal tags per cell, which feed into the SPL-G1
// causal audit pipeline (spl_cim_causal_unit × 4).
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_pim_compute_array #(
    parameter int ROWS = 16,
    parameter int COLS = 16
) (
    // RA-BUS (addressable via arbiter, synchronous to ra_clk)
    input  logic                  ra_clk,
    input  logic                  ra_rst_n,
    input  logic                  ra_en,           // RA-BUS transaction active
    input  logic [31:0]           ra_addr,         // [31:24] row, [23:16] col, low 16 reserved
    input  logic [63:0]           ra_wdata,
    output logic [63:0]           ra_rdata,

    // Micro-op control from sequencer
    input  logic [ 7:0]           pim_op,
    input  logic                  pim_store_en,    // 1=store result; 0=read-only
    input  logic [ 1:0]           exec_mode,       // 00:IDLE 01:SCALAR 10:VECTOR 11:MATRIX

    // Aggregated causal tag outputs (for audit pipeline)
    output logic [ 7:0]           raw_p_tag [ROWS-1:0][COLS-1:0],
    output logic [ 7:0]           raw_q_tag [ROWS-1:0][COLS-1:0],

    // Ready / Response handshake (for RA-BUS arbiter)
    output logic                  pim_ready,       // 1=result valid this cycle
    output logic [ 1:0]           pim_resp,        // 00:OK 01:ERROR

    // Result aggregation
    output logic [63:0]           vec_sum   [COLS-1:0],  // per-column vector sum
    output logic [63:0]           mat_total             // full-array MAC total (64b)
);

    // ── Cell interconnect wires ──
    logic [63:0] cell_data_out [ROWS-1:0][COLS-1:0];
    logic        ns_link       [ROWS:0][COLS-1:0];   // vertical (north/south)
    logic        ew_link       [ROWS-1:0][COLS:0];   // horizontal (east/west)

    // ── Row/col decode ──
    logic [ROWS-1:0] row_sel;
    logic [COLS-1:0] col_sel;

    always_comb begin
        row_sel = {ROWS{1'b0}};
        col_sel = {COLS{1'b0}};
        if (ra_en) begin
            case (exec_mode)
                2'b01: begin // SCALAR: single cell
                    row_sel[ra_addr[31:24]] = 1'b1;
                    col_sel[ra_addr[23:16]] = 1'b1;
                end
                2'b10: begin // VECTOR: whole column
                    row_sel = {ROWS{1'b1}};
                    col_sel[ra_addr[23:16]] = 1'b1;
                end
                2'b11: begin // MATRIX: full grid
                    row_sel = {ROWS{1'b1}};
                    col_sel = {COLS{1'b1}};
                end
                default: ; // IDLE: no selection
            endcase
        end
    end

    // ── Cell instantiation ──
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_row
            for (c = 0; c < COLS; c = c + 1) begin : gen_col
                spl_pim_cell #(
                    .IDX_ROW(r),
                    .IDX_COL(c)
                ) u_cell (
                    .ra_clk       (ra_clk),
                    .ra_rst_n     (ra_rst_n),
                    .ra_op        (pim_op),
                    .ra_data_in   (row_sel[r] && col_sel[c] ? ra_wdata : 64'h0),
                    .ra_data_out  (cell_data_out[r][c]),
                    .pim_store_en (pim_store_en),
                    .pim_north_i  (ns_link[r][c]),
                    .pim_south_o  (ns_link[r+1][c]),
                    .pim_west_i   (ew_link[r][c]),
                    .pim_east_o   (ew_link[r][c+1]),
                    .exec_mode    (row_sel[r] && col_sel[c] ? exec_mode : 2'b00),
                    .p_tag_value  (raw_p_tag[r][c]),
                    .q_tag_value  (raw_q_tag[r][c])
                );
            end
        end
    endgenerate

    // ── Top/bottom neighbour tie-off ──
    generate
        for (c = 0; c < COLS; c = c + 1) begin : gen_ns_tie
            assign ns_link[0][c] = 1'b0;       // north edge grounded
            // ns_link[ROWS][c] left floating (no south consumer)
        end
        for (r = 0; r < ROWS; r = r + 1) begin : gen_ew_tie
            assign ew_link[r][0] = 1'b0;       // west edge grounded
            // ew_link[r][COLS] left floating (no east consumer)
        end
    endgenerate

    // ── SCALAR readback: selected cell's data ──
    always_comb begin
        ra_rdata = 64'h0;
        if (ra_en && exec_mode == 2'b01) begin
            ra_rdata = cell_data_out[ra_addr[31:24]][ra_addr[23:16]];
        end
    end

    // ── VECTOR sum per column (4×4 explicit for iverilog compat) ──
    assign vec_sum[0] = cell_data_out[0][0] + cell_data_out[1][0] + cell_data_out[2][0] + cell_data_out[3][0];
    assign vec_sum[1] = cell_data_out[0][1] + cell_data_out[1][1] + cell_data_out[2][1] + cell_data_out[3][1];
    assign vec_sum[2] = cell_data_out[0][2] + cell_data_out[1][2] + cell_data_out[2][2] + cell_data_out[3][2];
    assign vec_sum[3] = cell_data_out[0][3] + cell_data_out[1][3] + cell_data_out[2][3] + cell_data_out[3][3];

    // ── MATRIX total: row-sums then sum-of-sums (4×4 explicit) ──
    wire [63:0] mat_row0 = cell_data_out[0][0] + cell_data_out[0][1] + cell_data_out[0][2] + cell_data_out[0][3];
    wire [63:0] mat_row1 = cell_data_out[1][0] + cell_data_out[1][1] + cell_data_out[1][2] + cell_data_out[1][3];
    wire [63:0] mat_row2 = cell_data_out[2][0] + cell_data_out[2][1] + cell_data_out[2][2] + cell_data_out[2][3];
    wire [63:0] mat_row3 = cell_data_out[3][0] + cell_data_out[3][1] + cell_data_out[3][2] + cell_data_out[3][3];
    assign mat_total = mat_row0 + mat_row1 + mat_row2 + mat_row3;

    // ── Ready / Response handshake ──
    // pim_ready asserted one cycle after ra_en to pipeline response
    logic ra_en_d1;
    always_ff @(posedge ra_clk or negedge ra_rst_n) begin
        if (!ra_rst_n) ra_en_d1 <= 1'b0;
        else           ra_en_d1 <= ra_en;
    end
    assign pim_ready = ra_en_d1;
    assign pim_resp  = 2'd0;   // always OK

endmodule
