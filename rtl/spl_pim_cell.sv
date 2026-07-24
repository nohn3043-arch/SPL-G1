// ============================================================================
// spl_pim_cell — Processing-In-Memory Compute Cell
// ============================================================================
// Each cell contains:
//   - 1-bit local storage (latch-based, zero-Vdd near-threshold capable)
//   - Local 8-op ALU (bit-serial capable, compose into wider datapaths)
//   - Neighbour interconnect taps: north/south (column) and east/west (row)
//
// Design intent:
//   - SCALAR: single cell targeted via RA-BUS addr decode
//   - VECTOR: column-parallel via bitline sharing
//   - MATRIX: full-array MAC via 2D ripple in PIM grid
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_pim_cell #(
    parameter IDX_ROW = 0,
    parameter IDX_COL = 0
) (
    // RA-BUS control (broadcast or addressed)
    input  logic        ra_clk,
    input  logic        ra_rst_n,
    input  logic [ 7:0] ra_op,         // micro-op (matched to sequencer)
    input  logic [63:0] ra_data_in,    // operand from bus
    input  logic        pim_store_en,   // 1=store ALU result; 0=read-only
    output logic [63:0] ra_data_out,   // result to bus

    // PIM neighbour interconnects (same bit-slice)
    input  logic        pim_north_i,   // data from north neighbour
    output logic        pim_south_o,   // data to   south neighbour
    input  logic        pim_west_i,    // data from west  neighbour
    output logic        pim_east_o,    // data to   east  neighbour

    // Cell-local state
    input  logic [ 1:0] exec_mode,     // 00:IDLE 01:SCALAR 10:VECTOR 11:MATRIX
    output logic [ 7:0] p_tag_value,   // P-causal tag: 4-bit op idx + 4-bit data hash
    output logic [ 7:0] q_tag_value    // Q-causal tag: result fingerprint
);

    // ── local storage (latch; PIM cell state) ──
    logic [63:0] local_store;

    // ── neighbour latch chain ──
    logic pim_north_l, pim_west_l;

    always_ff @(posedge ra_clk or negedge ra_rst_n) begin
        if (!ra_rst_n) begin
            pim_north_l <= 1'b0;
            pim_west_l  <= 1'b0;
        end else begin
            pim_north_l <= pim_north_i;
            pim_west_l  <= pim_west_i;
        end
    end

    // ── ALU core (8 ops) ──
    logic [63:0] alu_result;
    logic [ 5:0] shift_amt;

    assign shift_amt = ra_data_in[5:0];

    always @(*) begin
        case (ra_op)
            8'h00: alu_result = ra_data_in;                          // NOP / pass-through
            8'h01: alu_result = local_store + ra_data_in;            // ADD
            8'h02: alu_result = local_store - ra_data_in;            // SUB
            8'h03: alu_result = local_store * ra_data_in;            // MUL (64×64 -> low 64)
            8'h04: alu_result = local_store * ra_data_in;            // MAC (same as MUL, MAC tree in array-level)
            8'h05: alu_result = (local_store == ra_data_in) ? 64'h1 : 64'h0;  // CMP (equality)
            8'h06: alu_result = local_store << shift_amt;             // SHIFT left
            8'h07: alu_result = local_store ^ ra_data_in;            // LOGIC (XOR; row-compose for wider logic)
            default: alu_result = 64'hDEAD_BEEF_DEAD_BEEF;          // fault marker
        endcase
    end

    // ── mode-gated store (only store when explicitly told; pim_store_en protects from destructive reads) ──
    always @(posedge ra_clk or negedge ra_rst_n) begin
        if (!ra_rst_n) begin
            local_store <= {IDX_ROW[15:0], 16'h0, IDX_COL[15:0], 16'h0};  // init with grid position
        end else if (exec_mode != 2'b00 && pim_store_en) begin
            local_store <= alu_result;
        end
    end

    // ── neighbour forwarding ──
    assign pim_south_o = pim_north_i;  // vertical ripple: pass down
    assign pim_east_o  = pim_west_i;   // horizontal ripple: pass right

    // ── output: result from local store ──
    assign ra_data_out = local_store;

    // ── causal tags (P: what we did, Q: what we got) ──
    assign p_tag_value = {ra_op[3:0], ra_data_in[3:0]};
    assign q_tag_value = local_store[7:0];

endmodule
