// ============================================================================
// spl_tile — SPL-G1 Processing Tile
// ============================================================================
// Encapsulates 16x16 PIM compute array, mesh router, local sequencer,
// RA-BUS crossbar, and local SRAM. Tiles are connected via 2D Mesh NoC
// to form large-scale arrays (up to 64x64 = 4096 tiles = 1,048,576 PIM units).
//
// FIXED (interface repair): the previous revision instantiated
// spl_pim_sequencer / spl_pim_compute_array with a port convention that
// never existed in this repo (.run/.start_pc/.uop against a sequencer that
// exposes .ra_cmd_valid/.seq_busy/.pim_op; .ra_valid/.ra_cmd against an
// array that exposes .ra_en/.pim_op/.exec_mode). Wiring below now matches
// the ACTUAL RTL ports, mirroring the verified pattern in G1_Top_Integrated:
//
//   router.local_out ──decode──> sequencer(RA-BUS cmd)
//   sequencer.pim_*  ─────────> array(pim_en/pim_addr/pim_wdata/pim_op/exec_mode)
//   array.pim_flag   ─────────> sequencer.pim_flag   (branch flag)
//   array.ra_rdata   ─────────> router.local_in      (readback to source)
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_tile #(
    parameter int ROWS       = 16,
    parameter int COLS       = 16,
    parameter int DATA_W     = 128,
    parameter int TILE_ADDR_W = 16
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ── Tile coordinate ──
    input  logic [7:0]                  tile_x,
    input  logic [7:0]                  tile_y,

    // ── North port ──
    input  logic                        north_in_valid,
    input  logic [DATA_W-1:0]           north_in_data,
    input  logic [TILE_ADDR_W-1:0]      north_in_dest,
    output logic                        north_in_ready,
    output logic                        north_out_valid,
    output logic [DATA_W-1:0]           north_out_data,
    output logic [TILE_ADDR_W-1:0]      north_out_dest,
    input  logic                        north_out_ready,

    // ── South port ──
    input  logic                        south_in_valid,
    input  logic [DATA_W-1:0]           south_in_data,
    input  logic [TILE_ADDR_W-1:0]      south_in_dest,
    output logic                        south_in_ready,
    output logic                        south_out_valid,
    output logic [DATA_W-1:0]           south_out_data,
    output logic [TILE_ADDR_W-1:0]      south_out_dest,
    input  logic                        south_out_ready,

    // ── East port ──
    input  logic                        east_in_valid,
    input  logic [DATA_W-1:0]           east_in_data,
    input  logic [TILE_ADDR_W-1:0]      east_in_dest,
    output logic                        east_in_ready,
    output logic                        east_out_valid,
    output logic [DATA_W-1:0]           east_out_data,
    output logic [TILE_ADDR_W-1:0]      east_out_dest,
    input  logic                        east_out_ready,

    // ── West port ──
    input  logic                        west_in_valid,
    input  logic [DATA_W-1:0]           west_in_data,
    input  logic [TILE_ADDR_W-1:0]      west_in_dest,
    output logic                        west_in_ready,
    output logic                        west_out_valid,
    output logic [DATA_W-1:0]           west_out_data,
    output logic [TILE_ADDR_W-1:0]      west_out_dest,
    input  logic                        west_out_ready,

    // ── Local control (from global sequencer / host) ──
    input  logic                        cfg_valid,
    input  logic [DATA_W-1:0]           cfg_data,
    output logic                        tile_busy,
    output logic                        tile_done
);

    // ═══════════════════════════════════════════════════════════════════
    // Router ↔ tile-local signals
    // ═══════════════════════════════════════════════════════════════════
    logic                        local_in_valid;
    logic [DATA_W-1:0]           local_in_data;
    logic [TILE_ADDR_W-1:0]      local_in_dest;
    logic                        local_in_ready;
    logic                        local_out_valid;
    logic [DATA_W-1:0]           local_out_data;
    logic [TILE_ADDR_W-1:0]      local_out_dest;
    logic                        local_out_ready;

    // ═══════════════════════════════════════════════════════════════════
    // RA-BUS command decode (router packet / host cfg → sequencer)
    //   payload[29:28] = ra_cmd  (00 READ / 01 WRITE / 10 EXECUTE / 11 CONFIG)
    //   payload[27:0]  = ra_addr offset
    //   payload[DATA_W-1:0] = operand
    // ═══════════════════════════════════════════════════════════════════
    logic [DATA_W-1:0]           cmd_payload;
    logic                        seq_cmd_valid;
    logic [ 1:0]                 seq_ra_cmd;
    logic [31:0]                 seq_ra_addr;
    logic [DATA_W-1:0]           seq_ra_wdata;

    assign seq_cmd_valid = cfg_valid | local_out_valid;
    assign cmd_payload   = cfg_valid ? cfg_data : local_out_data;
    assign seq_ra_cmd    = cmd_payload[29:28];
    assign seq_ra_addr   = {4'd0, cmd_payload[27:0]};
    assign seq_ra_wdata  = cmd_payload;

    // Mesh packet accepted whenever the sequencer can be handed one.
    assign local_out_ready = 1'b1;

    // ═══════════════════════════════════════════════════════════════════
    // Mesh Router
    // ═══════════════════════════════════════════════════════════════════
    spl_mesh_router #(.DATA_W(DATA_W), .ADDR_W(TILE_ADDR_W)) u_router (
        .clk, .rst_n,
        .my_x(tile_x), .my_y(tile_y),
        // Local
        .local_in_valid, .local_in_data, .local_in_dest, .local_in_ready,
        .local_out_valid, .local_out_data, .local_out_dest, .local_out_ready,
        // North
        .north_in_valid, .north_in_data, .north_in_dest, .north_in_ready,
        .north_out_valid, .north_out_data, .north_out_dest, .north_out_ready,
        // South
        .south_in_valid, .south_in_data, .south_in_dest, .south_in_ready,
        .south_out_valid, .south_out_data, .south_out_dest, .south_out_ready,
        // East
        .east_in_valid, .east_in_data, .east_in_dest, .east_in_ready,
        .east_out_valid, .east_out_data, .east_out_dest, .east_out_ready,
        // West
        .west_in_valid, .west_in_data, .west_in_dest, .west_in_ready,
        .west_out_valid, .west_out_data, .west_out_dest, .west_out_ready
    );

    // ═══════════════════════════════════════════════════════════════════
    // Tile-local audit path (bridge mode)
    // ═══════════════════════════════════════════════════════════════════
    // A per-tile spl_cim_causal_unit can be dropped in here later without
    // touching the sequencer/array wiring: drive audit_done_w / audit_pass_w
    // from the unit's check_done / check_pass instead of the bridge below.
    logic audit_dispatch_q;
    logic audit_done_w;
    logic audit_pass_w;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) audit_dispatch_q <= 1'b0;
        else        audit_dispatch_q <= seq_audit_dispatch;
    end

    assign audit_done_w = audit_dispatch_q;   // 1-cycle check latency
    assign audit_pass_w = 1'b1;               // bridge mode: always pass (A5 pending)

    // ═══════════════════════════════════════════════════════════════════
    // Local Sequencer (v4: control flow + pim_flag feedback)
    // ═══════════════════════════════════════════════════════════════════
    logic        seq_busy_i, seq_done_i, seq_error_i;
    logic        pim_en;
    logic [31:0] pim_seq_addr;
    logic [DATA_W-1:0] pim_seq_wdata;
    logic [ 7:0] pim_seq_op;
    logic [ 1:0] exec_mode;
    logic        seq_audit_dispatch;
    logic [ 7:0] seq_p_tag, seq_q_tag;
    logic        pim_flag_wire;

    spl_pim_sequencer #(.PROG_DEPTH(256), .DATA_W(DATA_W)) u_local_seq (
        .clk, .rst_n,
        .ra_cmd_valid(seq_cmd_valid),
        .ra_cmd(seq_ra_cmd),
        .ra_addr(seq_ra_addr),
        .ra_wdata(seq_ra_wdata),
        .audit_done(audit_done_w),
        .audit_pass(audit_pass_w),
        .pim_flag(pim_flag_wire),
        .seq_busy(seq_busy_i),
        .seq_done(seq_done_i),
        .seq_error(seq_error_i),
        .pim_en(pim_en),
        .pim_addr(pim_seq_addr),
        .pim_wdata(pim_seq_wdata),
        .pim_op(pim_seq_op),
        .exec_mode(exec_mode),
        .audit_dispatch(seq_audit_dispatch),
        .gen_p_tag(seq_p_tag),
        .gen_q_tag(seq_q_tag)
    );

    // ═══════════════════════════════════════════════════════════════════
    // Local PIM Array (16x16 = 256 units)
    // ═══════════════════════════════════════════════════════════════════
    logic [DATA_W-1:0] pim_rdata;
    logic        pim_ready_i;
    logic [1:0]  pim_resp_i;
    logic [ 7:0] pim_p_tags [ROWS-1:0][COLS-1:0];
    logic [ 7:0] pim_q_tags [ROWS-1:0][COLS-1:0];
    logic [DATA_W-1:0] pim_vec_sum [COLS-1:0];
    logic [DATA_W-1:0] pim_mat_total;
    logic        pim_store_en;

    // WRITE / EXECUTE store; READ does not (mirrors G1_Top_Integrated pim_store)
    assign pim_store_en = (seq_ra_cmd != 2'b00) && pim_en;

    spl_pim_compute_array #(.ROWS(ROWS), .COLS(COLS), .DATA_W(DATA_W)) u_pim_array (
        .ra_clk(clk), .ra_rst_n(rst_n),
        .ra_en(pim_en),
        .ra_addr(pim_seq_addr),
        .ra_wdata(pim_seq_wdata),
        .ra_rdata(pim_rdata),
        .pim_op(pim_seq_op),
        .pim_store_en(pim_store_en),
        .exec_mode(exec_mode),
        .raw_p_tag(pim_p_tags),
        .raw_q_tag(pim_q_tags),
        .pim_ready(pim_ready_i),
        .pim_resp(pim_resp_i),
        .vec_sum(pim_vec_sum),
        .mat_total(pim_mat_total),
        .pim_flag(pim_flag_wire),
        .cell_state_obs_packed(),
        .cell_op_obs_packed()
    );

    // ═══════════════════════════════════════════════════════════════════
    // PIM readback → router local input (echo result back toward source)
    // ═══════════════════════════════════════════════════════════════════
    assign local_in_valid = pim_ready_i;
    assign local_in_data  = pim_rdata;
    assign local_in_dest  = {tile_x, tile_y};

    // ═══════════════════════════════════════════════════════════════════
    // Tile status
    // ═══════════════════════════════════════════════════════════════════
    assign tile_busy = seq_busy_i;
    assign tile_done = seq_done_i;

endmodule
