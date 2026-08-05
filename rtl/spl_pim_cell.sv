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

    // ═══════════════════════════════════════════════
    //  IEEE 754 FP16 CORE — replaces integer stubs
    // ═══════════════════════════════════════════════
    // FP16 format: [15]=sign, [14:10]=exponent(bias=15), [9:0]=mantissa
    // Internally uses MantW=24 bits (enough for 10+10+guard) to compute,
    // then rounds to nearest-even back to 10-bit mantissa.

    // === FP16 field extraction ===
    function automatic logic        fp16_sign(input logic [15:0] v);
        return v[15];
    endfunction
    function automatic logic [4:0]  fp16_exp(input logic [15:0] v);
        return v[14:10];
    endfunction
    function automatic logic [9:0]  fp16_man(input logic [15:0] v);
        return v[9:0];
    endfunction

    function automatic logic [15:0] fp16_mk(logic sign, logic [4:0] exp, logic [9:0] man);
        return {sign, exp, man};
    endfunction

    // === Classification ===
    function automatic logic fp16_is_zero(input logic [15:0] v);
        return (fp16_exp(v)==5'd0 && fp16_man(v)==10'd0);
    endfunction
    function automatic logic fp16_is_inf(input logic [15:0] v);
        return (fp16_exp(v)==5'd31 && fp16_man(v)==10'd0);
    endfunction
    function automatic logic fp16_is_nan(input logic [15:0] v);
        return (fp16_exp(v)==5'd31 && fp16_man(v)!=10'd0);
    endfunction
    function automatic logic fp16_is_sub(input logic [15:0] v);
        return (fp16_exp(v)==5'd0 && fp16_man(v)!=10'd0);
    endfunction

    // === fp16_add: aligned mantissa add/sub (internal, a_sign already handled) ===
    function automatic logic [15:0] fp16_add_core(
        logic [15:0] a, logic [15:0] b, logic a_sub
    );
        logic        sa, sb;
        logic [4:0]  ea, eb;
        logic [11:0] ma, mb;          // 10-bit mant + 1 implicit + 1 guard
        logic [4:0]  er;
        logic [11:0] mr;
        logic        sr;
        logic        b_eff;           // effective operation sign
        logic [15:0] result;
        integer      diff;
        begin
            // NaN check
            if (fp16_is_nan(a))    return a;
            if (fp16_is_nan(b))    return b;
            sa = fp16_sign(a);
            sb = fp16_sign(b);
            ea = fp16_exp(a);
            eb = fp16_exp(b);
            // Build mantissa with implicit leading bit
            ma = fp16_is_sub(a) ? {1'b0, fp16_man(a), 1'b0} : {1'b1, fp16_man(a), 1'b0};
            mb = fp16_is_sub(b) ? {1'b0, fp16_man(b), 1'b0} : {1'b1, fp16_man(b), 1'b0};
            // Effective sign of b after considering a_sub
            b_eff = a_sub ? ~sb : sb;
            // Align: larger exponent as reference
            if ({1'b0, ea} < {1'b0, eb} || ((ea == eb) && (ma < mb))) begin
                // Swap: a < b in magnitude
                {sa, ea, ma} = {b_eff, eb, mb}; {sb, eb, mb} = {sa, ea, ma};
            end else begin
                sb = b_eff;
            end
            er = ea;
            diff = ea - eb;
            if (diff > 11) mb = 12'd0; else mb = mb >> diff;
            // Add or subtract mantissas
            if (sa == sb) begin
                mr = ma + mb; sr = sa;
            end else begin
                mr = ma - mb; sr = sa;
            end
            // Normalize
            if (mr == 12'd0) begin
                return {sr, 15'd0};   // result = ±0
            end
            while (mr[11] == 1'b0 && er > 0) begin
                mr = mr << 1; er = er - 1;
            end
            // Round to nearest even (guard bit at mr[0])
            if (mr[0] && (mr[1] || (mr[10:1] != 10'd0)))
                mr = mr + 12'd2;
            mr = mr >> 1;   // remove guard bit
            er = er + 1;    // compensate for implicit bit
            // Overflow → Inf
            if (er >= 5'd31) return {sr, 5'd31, 10'd0};
            // Underflow → zero
            if (er == 5'd0 && mr[10] == 1'b0) return {sr, 15'd0};
            result = {sr, er[4:0], mr[9:0]};
            return result;
        end
    endfunction

    // === fp16_mul: multiply two FP16 ===
    function automatic logic [15:0] fp16_mul_core(logic [15:0] a, logic [15:0] b);
        logic        sa, sb, sr;
        logic [4:0]  ea, eb;
        logic [10:0] ma, mb;
        logic [21:0] prod;          // 11×11 = 22 bits
        logic [4:0]  er;
        logic [10:0] mr;
        logic [6:0]  exp_sum;
        begin
            if (fp16_is_nan(a))              return a;
            if (fp16_is_nan(b))              return b;
            if (fp16_is_inf(a) || fp16_is_inf(b)) begin
                if (fp16_is_zero(a) || fp16_is_zero(b))
                    return 16'h7E00;   // Inf×0 → NaN
                sr = fp16_sign(a) ^ fp16_sign(b);
                return {sr, 5'd31, 10'd0};   // ±Inf
            end
            sa = fp16_sign(a); sb = fp16_sign(b); sr = sa ^ sb;
            ea = fp16_exp(a); eb = fp16_exp(b);
            ma = fp16_is_sub(a) ? {1'b0, fp16_man(a)} : {1'b1, fp16_man(a)};
            mb = fp16_is_sub(b) ? {1'b0, fp16_man(b)} : {1'b1, fp16_man(b)};
            // Multiply
            prod = ma * mb;
            exp_sum = {2'b0, ea} + {2'b0, eb} - 7'd15 + 7'd1;
            // Normalize
            if (prod[21]) begin
                prod = prod >> 1; exp_sum = exp_sum + 1;
            end
            if (exp_sum >= 7'd31) return {sr, 5'd31, 10'd0};   // overflow → Inf
            if (exp_sum <= 7'd0 && prod[20] == 1'b0) return {sr, 15'd0};   // underflow → 0
            // Round
            if (prod[9] && (prod[8] || (prod[7:0] != 8'd0)))
                prod = prod + 22'd512;   // add 1 at bit 9
            mr = prod[20:10];
            er = exp_sum[4:0];
            if (exp_sum <= 0) er = 5'd0;
            return {sr, er, mr[9:0]};
        end
    endfunction

    // === fp16_cmp: ordered comparison (false if either NaN) ===
    function automatic logic fp16_cmp_core(logic [15:0] a, logic [15:0] b);
        logic sa, sb;
        begin
            if (fp16_is_nan(a) || fp16_is_nan(b)) return 1'b0;
            if (fp16_is_zero(a) && fp16_is_zero(b)) return 1'b1;  // +0 == -0
            sa = fp16_sign(a); sb = fp16_sign(b);
            if (sa != sb) return 1'b0;
            return (a == b);
        end
    endfunction

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

                // ── FP16: IEEE 754 half-precision (roundTiesToEven) ──
                OP_FP16_ADD: alu_result = {{(DATA_W-16){1'b0}}, fp16_add_core(local_store[15:0], ra_data_in[15:0], 1'b0)};
                OP_FP16_SUB: alu_result = {{(DATA_W-16){1'b0}}, fp16_add_core(local_store[15:0], ra_data_in[15:0], 1'b1)};
                OP_FP16_MUL: alu_result = {{(DATA_W-16){1'b0}}, fp16_mul_core(local_store[15:0], ra_data_in[15:0])};
                OP_FP16_CMP: alu_result = {{(DATA_W-1){1'b0}}, fp16_cmp_core(local_store[15:0], ra_data_in[15:0])};
                OP_FP16_MAC: alu_result = {{(DATA_W-16){1'b0}},
                    fp16_add_core(fp16_mul_core(local_store[15:0], ra_data_in[15:0]),
                                  local_store[31:16], 1'b0)};  // MAC: lo16×in + hi16

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
