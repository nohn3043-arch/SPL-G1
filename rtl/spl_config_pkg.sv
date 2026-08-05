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
    //  [0] NS → CIM_SRAM_Filter_Array
    localparam string OP0_CELL     = "CIM_SRAM_Filter_Array";
    localparam real   OP0_DELAY_NS = 1.2;
    localparam real   OP0_POWER_MW = 5.5;
    localparam real   OP0_AREA_UM2 = 120.0;
    localparam real   OP0_SNR_DB   = 45.0;
    localparam real   OP0_VOLTAGE_V = 0.8;

    //  [1] NS → CIM_SRAM_Filter_Array
    localparam string OP1_CELL     = "CIM_SRAM_Filter_Array";
    localparam real   OP1_DELAY_NS = 1.2;
    localparam real   OP1_POWER_MW = 5.5;
    localparam real   OP1_AREA_UM2 = 120.0;
    localparam real   OP1_SNR_DB   = 45.0;
    localparam real   OP1_VOLTAGE_V = 0.8;

    //  [2] IAP → CIM_Comparator_Logic
    localparam string OP2_CELL     = "CIM_Comparator_Logic";
    localparam real   OP2_DELAY_NS = 0.8;
    localparam real   OP2_POWER_MW = 8.2;
    localparam real   OP2_AREA_UM2 = 85.0;
    localparam real   OP2_SNR_DB   = 50.0;

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

    //  [5] STATE → Non_Volatile_RRAM_Anchor
    localparam string OP5_CELL     = "Non_Volatile_RRAM_Anchor";
    localparam real   OP5_DELAY_NS = 0.5;
    localparam real   OP5_POWER_MW = 2.0;
    localparam real   OP5_AREA_UM2 = 45.0;
    localparam real   OP5_SNR_DB   = 60.0;
    localparam real   OP5_RETENTION_YEARS = 10;

endpackage
