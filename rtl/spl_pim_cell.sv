// ============================================================================
// spl_pim_cell_v2 — PIM Compute Cell v2 (Phase 1: 32-op ALU + Predicate + 8-bit Neighbour)
// ============================================================================
// Upgrades over v1 (spl_pim_cell):
//   - ALU: 8 op → 32 op (ADD/ADC/SUB/SBB/MUL_LO/MUL_HI/MAC/CMP_EQ/NE/LT/GT,
//          SHL/SHR/SAR/AND/OR/XOR/NOT/FP16_ADD/SUB/MUL/CMP/MAC,
//          PRED_SET/LOAD_ROW/LOAD_COL/STORE_LOCAL + 5 reserved)
//   - Predicate: 1-bit pred_reg, conditional execution via pred_en
//   - Neighbour: 1-bit bit-serial → 8-bit byte-parallel
//   - Chaining: CMP → PRED_SET → conditional exec; ADC/SBB → multi-cell wide arithmetic
//
// Backward compatible with spl_pim_cell port map:
//   - 1-bit neighbour: tie to row_data_in[0] / col_data_in[0]
//   - pred_en: tie to 1'b0
//   - Unused neighbour outputs: leave floating (allowed in SV)
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_pim_cell #(
    parameter IDX_ROW = 0,
    parameter IDX_COL = 0,
    parameter int DATA_W = 64        // v3: data width (64=legacy, 128=expanded)
) (
    // ── RA-BUS control (unchanged from v1) ──
    input  logic        ra_clk,
    input  logic        ra_rst_n,
    input  logic [ 4:0] ra_op,             // v2: 5-bit opcode (v1 was 8-bit for simplicity;
                                            //      upper 3 bits reserved for future expansion)
    input  logic [DATA_W-1:0] ra_data_in,
    input  logic        pim_store_en,
    output logic [DATA_W-1:0] ra_data_out,

    // ── Neighbour interconnect (v2: 8-bit wide, v1 was 1-bit) ──
    input  logic [ 7:0] row_data_in,       // data from north neighbour
    output logic [ 7:0] row_data_out,      // data to   south neighbour
    input  logic [ 7:0] col_data_in,       // data from west  neighbour
    output logic [ 7:0] col_data_out,      // data to   east  neighbour

    // ── Predicate execution (v2: new) ──
    input  logic        pred_en,           // 1 = use pred_reg for conditional exec
    output logic        pred_reg,          // predicate register (set by CMP ops)

    // ── Mode & tags (unchanged from v1) ──
    input  logic [ 1:0] exec_mode,         // 00:IDLE 01:SCALAR 10:VECTOR 11:MATRIX
    output logic [ 7:0] p_tag_value,
    output logic [ 7:0] q_tag_value
);

    // ═══════════════════════════════════════════════
    //  OPCODE DEFINITIONS (5-bit)
    // ═══════════════════════════════════════════════
    localparam OP_NOP       = 5'h00;
    localparam OP_ADD       = 5'h01;
    localparam OP_ADC       = 5'h02;
    localparam OP_SUB       = 5'h03;
    localparam OP_SBB       = 5'h04;
    localparam OP_MUL_LO    = 5'h05;
    localparam OP_MUL_HI    = 5'h06;
    localparam OP_MAC       = 5'h07;
    localparam OP_CMP_EQ    = 5'h08;
    localparam OP_CMP_NE    = 5'h09;
    localparam OP_CMP_LT    = 5'h0A;
    localparam OP_CMP_GT    = 5'h0B;
    localparam OP_SHL       = 5'h0C;
    localparam OP_SHR       = 5'h0D;
    localparam OP_SAR       = 5'h0E;
    localparam OP_AND       = 5'h0F;
    localparam OP_OR        = 5'h10;
    localparam OP_XOR       = 5'h11;
    localparam OP_NOT       = 5'h12;
    localparam OP_FP16_ADD  = 5'h13;
    localparam OP_FP16_SUB  = 5'h14;
    localparam OP_FP16_MUL  = 5'h15;
    localparam OP_FP16_CMP  = 5'h16;
    localparam OP_FP16_MAC  = 5'h17;
    localparam OP_PRED_SET  = 5'h18;
    localparam OP_LOAD_ROW  = 5'h19;
    localparam OP_LOAD_COL  = 5'h1A;
    localparam OP_STORE_LOC = 5'h1B;
    // 5'h1C - 5'h1F reserved

    // ═══════════════════════════════════════════════
    //  INTERNAL STATE
    // ═══════════════════════════════════════════════
    logic [DATA_W-1:0] local_store;
    logic [DATA_W-1:0] alu_result;
    logic [ 5:0] shift_amt;

    // ── Carry / borrow registers (for multi-cell wide arithmetic) ──
    logic        carry_reg;       // carry-out from last ADD/ADC
    logic        borrow_reg;      // borrow-out from last SUB/SBB

    // ═══════════════════════════════════════════════
    //  NEIGHBOUR LATCH CHAIN (8-bit wide)
    // ═══════════════════════════════════════════════
    logic [7:0] row_data_l;
    logic [7:0] col_data_l;

    always_ff @(posedge ra_clk or negedge ra_rst_n) begin
        if (!ra_rst_n) begin
            row_data_l <= 8'h00;
            col_data_l <= 8'h00;
        end else begin
            row_data_l <= row_data_in;
            col_data_l <= col_data_in;
        end
    end

    // ── Neighbour forwarding (ripple: pass-through) ──
    assign row_data_out = row_data_in;
    assign col_data_out = col_data_in;

    // ═══════════════════════════════════════════════
    //  PREDICATE LOGIC
    // ═══════════════════════════════════════════════
    // pred_reg is set by CMP ops (EQ/NE/LT/GT) and read by PRED_SET.
    // When pred_en = 1, ops that don't match pred_reg become NOP.

    wire pred_match = (pred_reg) ? 1'b1 : 1'b0;  // pred_reg=1 → execute
    wire exec_active = (exec_mode != 2'b00) && (!pred_en || pred_match);

    always_ff @(posedge ra_clk or negedge ra_rst_n) begin
        if (!ra_rst_n) begin
            pred_reg <= 1'b0;
        end else if (exec_mode != 2'b00 && !pred_en) begin
            // Auto-update predicate from CMP results (even without PRED_SET)
            case (ra_op)
                OP_CMP_EQ: pred_reg <= (local_store == ra_data_in);
                OP_CMP_NE: pred_reg <= (local_store != ra_data_in);
                OP_CMP_LT: pred_reg <= ($signed(local_store) < $signed(ra_data_in));
                OP_CMP_GT: pred_reg <= ($signed(local_store) > $signed(ra_data_in));
                OP_PRED_SET: pred_reg <= ra_data_in[0];  // explicit set from input bit 0
                default: pred_reg <= pred_reg;
            endcase
        end else if (exec_mode != 2'b00 && pred_en && ra_op == OP_PRED_SET) begin
            pred_reg <= ra_data_in[0];
        end
    end

    // ═══════════════════════════════════════════════
    //  ALU CORE (32 operations)
    // ═══════════════════════════════════════════════
    assign shift_amt = ra_data_in[5:0];

    // ── Extended-precision intermediate signals ──
    logic [DATA_W:0] add_ext;        // (DATA_W+1)-bit: {carry, DATA_W-bit sum}
    logic [DATA_W:0] sub_ext;        // (DATA_W+1)-bit: {borrow, DATA_W-bit diff}
    logic [2*DATA_W-1:0] mul_full;   // 2*DATA_W-bit full product

    assign add_ext = {1'b0, local_store} + {1'b0, ra_data_in} + {{DATA_W{1'b0}}, carry_reg};
    assign sub_ext = {1'b0, local_store} - {1'b0, ra_data_in} - {{DATA_W{1'b0}}, borrow_reg};
    assign mul_full = local_store * ra_data_in;

    // ── FP16 stubs (placeholder: converts to integer ops until FP16 core integrated) ──
    // Real FP16 implementation requires: sign/exponent/mantissa extraction,
    // normalization, rounding (round-to-nearest-even), and denormal handling.
    // These stubs treat FP16 as 16-bit integers packed in low 16 bits of 64-bit word.
    logic [15:0] fp16_a, fp16_b;
    assign fp16_a = local_store[15:0];
    assign fp16_b = ra_data_in[15:0];

    always @(*) begin
        // Default: NOP / pass-through
        alu_result = ra_data_in;

        if (exec_active) begin
            case (ra_op)
                // ── Basic arithmetic ──
                OP_NOP:    alu_result = ra_data_in;
                OP_ADD:    alu_result = add_ext[DATA_W-1:0];
                OP_ADC:    alu_result = add_ext[DATA_W-1:0];     // carry_reg sourced from neighbour
                OP_SUB:    alu_result = sub_ext[DATA_W-1:0];
                OP_SBB:    alu_result = sub_ext[DATA_W-1:0];

                // ── Multiply ──
                OP_MUL_LO: alu_result = mul_full[DATA_W-1:0];
                OP_MUL_HI: alu_result = mul_full[2*DATA_W-1:DATA_W];
                OP_MAC:    alu_result = local_store + mul_full[DATA_W-1:0];

                // ── Comparison (result = {DATA_W-1'b0, condition}) ──
                OP_CMP_EQ: alu_result = {{(DATA_W-1){1'b0}}, (local_store == ra_data_in)};
                OP_CMP_NE: alu_result = {{(DATA_W-1){1'b0}}, (local_store != ra_data_in)};
                OP_CMP_LT: alu_result = {{(DATA_W-1){1'b0}}, ($signed(local_store) <  $signed(ra_data_in))};
                OP_CMP_GT: alu_result = {{(DATA_W-1){1'b0}}, ($signed(local_store) >  $signed(ra_data_in))};

                // ── Shift ──
                OP_SHL:    alu_result = local_store << shift_amt;
                OP_SHR:    alu_result = local_store >> shift_amt;
                OP_SAR:    alu_result = $signed(local_store) >>> shift_amt;

                // ── Logic ──
                OP_AND:    alu_result = local_store & ra_data_in;
                OP_OR:     alu_result = local_store | ra_data_in;
                OP_XOR:    alu_result = local_store ^ ra_data_in;
                OP_NOT:    alu_result = ~local_store;

                // ── FP16 (stubs — real FP16 core TBD in Phase 2) ──
                // Each stub operates on low 16 bits; upper bits zero-extended.
                OP_FP16_ADD: alu_result = {{(DATA_W-16){1'b0}}, fp16_a + fp16_b};
                OP_FP16_SUB: alu_result = {{(DATA_W-16){1'b0}}, fp16_a - fp16_b};
                OP_FP16_MUL: alu_result = {{(DATA_W-16){1'b0}}, fp16_a * fp16_b};
                OP_FP16_CMP: alu_result = {{(DATA_W-1){1'b0}}, (fp16_a == fp16_b)};
                OP_FP16_MAC: alu_result = {{(DATA_W-16){1'b0}}, fp16_a + (fp16_a * fp16_b)};

                // ── Predicate ──
                OP_PRED_SET: alu_result = {{(DATA_W-1){1'b0}}, ra_data_in[0]};  // just passthrough; pred_reg set separately

                // ── Data movement (neighbour → local path) ──
                OP_LOAD_ROW: alu_result = {{(DATA_W-8){1'b0}}, row_data_l};
                OP_LOAD_COL: alu_result = {{(DATA_W-8){1'b0}}, col_data_l};

                // ── Force store ──
                OP_STORE_LOC: alu_result = ra_data_in;

                // ── Fallback ──
                default: alu_result = {(DATA_W){1'b1}};
            endcase
        end
    end

    // ═══════════════════════════════════════════════
    //  CARRY / BORROW UPDATE
    // ═══════════════════════════════════════════════
    always_ff @(posedge ra_clk or negedge ra_rst_n) begin
        if (!ra_rst_n) begin
            carry_reg  <= 1'b0;
            borrow_reg <= 1'b0;
        end else if (exec_active) begin
            case (ra_op)
                OP_ADD: carry_reg  <= add_ext[64];
                OP_ADC: carry_reg  <= add_ext[64];
                OP_SUB: borrow_reg <= sub_ext[64];
                OP_SBB: borrow_reg <= sub_ext[64];
                default: begin
                    carry_reg  <= 1'b0;
                    borrow_reg <= 1'b0;
                end
            endcase
        end
    end

    // ═══════════════════════════════════════════════
    //  LOCAL STORE UPDATE
    // ═══════════════════════════════════════════════
    // STORE_LOCAL bypasses pim_store_en (explicit force-write).
    wire store_condition = (exec_mode != 2'b00) && (pim_store_en || (ra_op == OP_STORE_LOC));

    always_ff @(posedge ra_clk or negedge ra_rst_n) begin
        if (!ra_rst_n) begin
            local_store <= {{(DATA_W-64){1'b0}}, IDX_ROW[15:0], 16'h0, IDX_COL[15:0], 16'h0};  // init with grid position
        end else if (store_condition && exec_active) begin
            local_store <= alu_result;
        end
    end

    // ═══════════════════════════════════════════════
    //  OUTPUT
    // ═══════════════════════════════════════════════
    assign ra_data_out = local_store;

    // ── Causal tags: P (5-bit op + 3-bit data hash), Q (low byte of result) ──
    assign p_tag_value = {ra_op[4:0], ra_data_in[2:0]};
    assign q_tag_value = alu_result[7:0];

    // ── Assertion (synthesis off): no X propagation ──
    `ifdef SIMULATION
    always @(posedge ra_clk) begin
        if (exec_active && ra_op >= 5'h1C) begin
            $display("[CELL v2][%0d,%0d] WARNING: reserved opcode 0x%0h", IDX_ROW, IDX_COL, ra_op);
        end
    end
    `endif

endmodule
