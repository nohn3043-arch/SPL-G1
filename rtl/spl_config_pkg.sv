// ============================================================================
// spl_config_pkg — Auto-generated from EDA mapping: causal_chain_demo
// DO NOT EDIT MANUALLY — regenerate with: python eda_cli.py --rtl --apply-rtl
// ============================================================================

package spl_config_pkg;

    // ── Design: causal_chain_demo ──
    localparam string DESIGN_NAME = "causal_chain_demo";
    localparam string MATERIAL    = "silicon_cim_28nm_v1";
    localparam string STRATEGY    = "min_delay";

    // ── Array geometry (EDA-driven; G1_Top reads these) ──
    localparam int    PIM_ROWS    = 64;
    localparam int    PIM_COLS    = 64;

    localparam real   MAX_DELAY_NS = 10.0;
    localparam real   MAX_POWER_MW = 100.0;
    localparam real   MAX_AREA_UM2 = 1000000.0;
    localparam real   MIN_SNR_DB   = 20.0;

    // ── Causal op type encoding ──
    typedef enum logic [2:0] {
        OP_CCS = 3'd0,
        OP_IAP = 3'd1,
        OP_LCH = 3'd2,
        OP_NS = 3'd3,
        OP_STATE = 3'd4
    } causal_op_type_t;

    // ── Op-specific configuration ──
    //  [0] NS → CIM_SRAM_Filter_Fast
    localparam string OP0_CELL     = "CIM_SRAM_Filter_Fast";
    localparam real   OP0_DELAY_NS = 0.8;
    localparam real   OP0_POWER_MW = 9.0;
    localparam real   OP0_AREA_UM2 = 180.0;
    localparam real   OP0_SNR_DB   = 48.0;
    localparam real   OP0_VOLTAGE_V = 1.0;
    localparam real   OP0_FILTER_WIDTH = 256;

    //  [1] NS → CIM_SRAM_Filter_Fast
    localparam string OP1_CELL     = "CIM_SRAM_Filter_Fast";
    localparam real   OP1_DELAY_NS = 0.8;
    localparam real   OP1_POWER_MW = 9.0;
    localparam real   OP1_AREA_UM2 = 180.0;
    localparam real   OP1_SNR_DB   = 48.0;
    localparam real   OP1_VOLTAGE_V = 1.0;
    localparam real   OP1_FILTER_WIDTH = 256;

    //  [2] IAP → CIM_Comparator_Fast
    localparam string OP2_CELL     = "CIM_Comparator_Fast";
    localparam real   OP2_DELAY_NS = 0.5;
    localparam real   OP2_POWER_MW = 14.0;
    localparam real   OP2_AREA_UM2 = 140.0;
    localparam real   OP2_SNR_DB   = 53.0;
    localparam real   OP2_VOLTAGE_V = 1.0;

    //  [3] LCH → CIM_Loop_Guard_Logic
    localparam string OP3_CELL     = "CIM_Loop_Guard_Logic";
    localparam real   OP3_DELAY_NS = 0.3;
    localparam real   OP3_POWER_MW = 1.5;
    localparam real   OP3_AREA_UM2 = 40.0;
    localparam real   OP3_SNR_DB   = 65.0;

    //  [4] CCS → Digital_DLL_Sync
    localparam string OP4_CELL     = "Digital_DLL_Sync";
    localparam real   OP4_DELAY_NS = 0.1;
    localparam real   OP4_POWER_MW = 1.2;
    localparam real   OP4_AREA_UM2 = 30.0;
    localparam real   OP4_SNR_DB   = 80.0;
    localparam real   OP4_JITTER_PS = 15;

    //  [5] STATE → SRAM_Anchor_Fast
    localparam string OP5_CELL     = "SRAM_Anchor_Fast";
    localparam real   OP5_DELAY_NS = 0.3;
    localparam real   OP5_POWER_MW = 4.0;
    localparam real   OP5_AREA_UM2 = 70.0;
    localparam real   OP5_SNR_DB   = 63.0;
    localparam real   OP5_RETENTION_YEARS = 0;
    localparam real   OP5_VOLTAGE_V = 1.0;

    // ════════════════════════════════════════════════════════════
    // ── Backend semantics (v0.2.0): micro-op sequences + audit records ──
    // ════════════════════════════════════════════════════════════
    //  [0] NS backend sequence (Narrative strip: normalize (SUB) then mask (AND) then predicate-gate (CMP_GT→PRED_SET))
    localparam logic [4:0] OP0_MICRO_OP   = 5'h03;  // lead opcode
    localparam string OP0_MICRO_SEQ  = "SUB → AND → CMP_GT → PRED_SET";
    localparam string OP0_MICRO_HEX  = "0x03, 0x0F, 0x0B, 0x18";
    //  audit record: rule=0x01 dep_mask=00000000000000 weight_q16_16=0x10000
    localparam logic [255:0] OP0_AUDIT_P = 256'h0100000000000000ffffffffffffffff00000000000100000000000000000000;
    localparam logic [255:0] OP0_AUDIT_Q = 256'h000000000000000000000000000000000000000000000000ddf06bbf814c0000;

    //  [1] NS backend sequence (Narrative strip: normalize (SUB) then mask (AND) then predicate-gate (CMP_GT→PRED_SET))
    localparam logic [4:0] OP1_MICRO_OP   = 5'h03;  // lead opcode
    localparam string OP1_MICRO_SEQ  = "SUB → AND → CMP_GT → PRED_SET";
    localparam string OP1_MICRO_HEX  = "0x03, 0x0F, 0x0B, 0x18";
    //  audit record: rule=0x01 dep_mask=00000000000000 weight_q16_16=0x10000
    localparam logic [255:0] OP1_AUDIT_P = 256'h0100000000000000ffffffffffffffff00000000000100000000000000000000;
    localparam logic [255:0] OP1_AUDIT_Q = 256'h000000000000000000000000000000000000000000000000ddf06bbf814c0001;

    //  [2] IAP backend sequence (Assumption detect: divergence (CMP_NE) + delta (SUB) + threshold (CMP_GT))
    localparam logic [4:0] OP2_MICRO_OP   = 5'h09;  // lead opcode
    localparam string OP2_MICRO_SEQ  = "CMP_NE → SUB → CMP_GT → PRED_SET";
    localparam string OP2_MICRO_HEX  = "0x09, 0x03, 0x0B, 0x18";
    //  audit record: rule=0x02 dep_mask=00000000000003 weight_q16_16=0x10000
    localparam logic [255:0] OP2_AUDIT_P = 256'h0200000000000003ffffffffffffffff00000000000100000000000000000000;
    localparam logic [255:0] OP2_AUDIT_Q = 256'h000000000000000000000000000000000000000000000000ddf06bbf814c0002;

    //  [3] LCH backend sequence (Fragility hedge: bounds check (CMP_GT/CMP_LT) + predicate select + clamp (SUB/ADD))
    localparam logic [4:0] OP3_MICRO_OP   = 5'h0B;  // lead opcode
    localparam string OP3_MICRO_SEQ  = "CMP_GT → PRED_SET → CMP_LT → SUB";
    localparam string OP3_MICRO_HEX  = "0x0B, 0x18, 0x0A, 0x03";
    //  audit record: rule=0x03 dep_mask=00000000000004 weight_q16_16=0x10000
    localparam logic [255:0] OP3_AUDIT_P = 256'h0300000000000004ffffffffffffffff00000000000100000000000000000000;
    localparam logic [255:0] OP3_AUDIT_Q = 256'h000000000000000000000000000000000000000000000000ddf06bbf814c0003;

    //  [4] CCS backend sequence (Clock sync: alignment correction (SUB) + skew detect (CMP_NE) + barrier (PRED_SET))
    localparam logic [4:0] OP4_MICRO_OP   = 5'h03;  // lead opcode
    localparam string OP4_MICRO_SEQ  = "SUB → CMP_NE → PRED_SET → NOP";
    localparam string OP4_MICRO_HEX  = "0x03, 0x09, 0x18, 0x00";
    //  audit record: rule=0x04 dep_mask=00000000000003 weight_q16_16=0x10000
    localparam logic [255:0] OP4_AUDIT_P = 256'h0400000000000003ffffffffffffffff00000000000100000000000000000000;
    localparam logic [255:0] OP4_AUDIT_Q = 256'h000000000000000000000000000000000000000000000000ddf06bbf814c0004;

    //  [5] STATE backend sequence (State update: readback (LOAD_ROW) + increment (ADD) + persist (STORE_LOC))
    localparam logic [4:0] OP5_MICRO_OP   = 5'h19;  // lead opcode
    localparam string OP5_MICRO_SEQ  = "LOAD_ROW → ADD → STORE_LOC → NOP";
    localparam string OP5_MICRO_HEX  = "0x19, 0x01, 0x1B, 0x00";
    //  audit record: rule=0x05 dep_mask=00000000000018 weight_q16_16=0x10000
    localparam logic [255:0] OP5_AUDIT_P = 256'h0500000000000018ffffffffffffffff00000000000100000000000000000000;
    localparam logic [255:0] OP5_AUDIT_Q = 256'h000000000000000000000000000000000000000000000000ddf06bbf814c0005;

endpackage
