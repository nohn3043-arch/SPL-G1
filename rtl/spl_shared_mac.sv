// ============================================================================
// spl_shared_mac — Array-level shared wide multiplier (option-2)
// ============================================================================
// The PIM cell no longer instantiates a DATA_W×DATA_W multiplier. Instead a
// single shared MAC serves the whole array; cells forward operands and consume
// the product. Only the cell selected by row_sel/col_sel (SCALAR mode) may
// drive it — VECTOR/MATRIX wide-MUL needs sequencer serialization.
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_shared_mac #(
    parameter int DATA_W = 64
) (
    input  logic [DATA_W-1:0]   a,
    input  logic [DATA_W-1:0]   b,
    output logic [2*DATA_W-1:0] p
);

    assign p = a * b;

endmodule