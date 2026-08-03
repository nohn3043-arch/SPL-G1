// ============================================================================
// spl_tile — SPL-G1 Processing Tile
// ============================================================================
// Encapsulates 16x16 PIM compute array, mesh router, local sequencer,
// RA-BUS crossbar, and local SRAM. Tiles are connected via 2D Mesh NoC
// to form large-scale arrays (up to 64x64 = 4096 tiles = 1,048,576 PIM units).
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
    input  logic                        north_out_ready,

    // ── South port ──
    input  logic                        south_in_valid,
    input  logic [DATA_W-1:0]           south_in_data,
    input  logic [TILE_ADDR_W-1:0]      south_in_dest,
    output logic                        south_in_ready,
    output logic                        south_out_valid,
    output logic [DATA_W-1:0]           south_out_data,
    input  logic                        south_out_ready,

    // ── East port ──
    input  logic                        east_in_valid,
    input  logic [DATA_W-1:0]           east_in_data,
    input  logic [TILE_ADDR_W-1:0]      east_in_dest,
    output logic                        east_in_ready,
    output logic                        east_out_valid,
    output logic [DATA_W-1:0]           east_out_data,
    input  logic                        east_out_ready,

    // ── West port ──
    input  logic                        west_in_valid,
    input  logic [DATA_W-1:0]           west_in_data,
    input  logic [TILE_ADDR_W-1:0]      west_in_dest,
    output logic                        west_in_ready,
    output logic                        west_out_valid,
    output logic [DATA_W-1:0]           west_out_data,
    input  logic                        west_out_ready,

    // ── Local control (from global sequencer / host) ──
    input  logic                        cfg_valid,
    input  logic [DATA_W-1:0]           cfg_data,
    output logic                        tile_busy,
    output logic                        tile_done
);

    // ── Internal signals ──
    logic                        local_in_valid;
    logic [DATA_W-1:0]           local_in_data;
    logic [TILE_ADDR_W-1:0]      local_in_dest;
    logic                        local_in_ready;
    logic                        local_out_valid;
    logic [DATA_W-1:0]           local_out_data;
    logic                        local_out_ready;

    logic                        pim_valid;
    logic [1:0]                  pim_cmd;
    logic [15:0]                 pim_addr;
    logic [DATA_W-1:0]           pim_wdata;
    logic [DATA_W-1:0]           pim_rdata;
    logic                        pim_ready;
    logic [1:0]                  pim_resp;

    logic                        ra_valid;
    logic [1:0]                  ra_cmd;
    logic [27:0]                 ra_addr;
    logic [DATA_W-1:0]           ra_wdata;
    logic [DATA_W-1:0]           ra_rdata;
    logic                        ra_ready;
    logic [1:0]                  ra_resp;

    logic                        seq_run;
    logic [15:0]                 seq_start_pc;
    logic                        seq_busy;
    logic                        seq_done;
    logic [DATA_W-1:0]           seq_uop;
    logic                        seq_uop_valid;

    // ── Mesh Router ──
    spl_mesh_router #(.DATA_W(DATA_W), .ADDR_W(TILE_ADDR_W)) u_router (
        .clk, .rst_n,
        .my_x(tile_x), .my_y(tile_y),
        // Local
        .local_in_valid, .local_in_data, .local_in_dest, .local_in_ready,
        .local_out_valid, .local_out_data, .local_out_ready,
        // North
        .north_in_valid, .north_in_data, .north_in_dest, .north_in_ready,
        .north_out_valid, .north_out_data, .north_out_ready,
        // South
        .south_in_valid, .south_in_data, .south_in_dest, .south_in_ready,
        .south_out_valid, .south_out_data, .south_out_ready,
        // East
        .east_in_valid, .east_in_data, .east_in_dest, .east_in_ready,
        .east_out_valid, .east_out_data, .east_out_ready,
        // West
        .west_in_valid, .west_in_data, .west_in_dest, .west_in_ready,
        .west_out_valid, .west_out_data, .west_out_ready
    );

    // ── Local PIM Array (16x16 = 256 units) ──
    spl_pim_compute_array #(.ROWS(ROWS), .COLS(COLS), .DATA_W(DATA_W)) u_pim_array (
        .clk, .rst_n,
        .ra_valid(pim_valid), .ra_cmd(pim_cmd), .ra_addr(pim_addr),
        .ra_wdata(pim_wdata), .ra_rdata(pim_rdata),
        .ra_ready(pim_ready), .ra_resp(pim_resp)
    );

    // ── Local Sequencer ──
    spl_pim_sequencer #(.PROG_DEPTH(256), .DATA_W(DATA_W)) u_local_seq (
        .clk, .rst_n,
        .run(seq_run), .start_pc(seq_start_pc),
        .ra_ready(ra_ready), .ra_resp(ra_resp), .ra_rdata(ra_rdata),
        .busy(seq_busy), .done(seq_done),
        .ra_valid(ra_valid), .ra_cmd(ra_cmd), .ra_addr(ra_addr),
        .ra_wdata(ra_wdata), .uop(seq_uop), .uop_valid(seq_uop_valid)
    );

    // ── Local RA-BUS crossbar (connects router local port to PIM/sequencer) ──
    // Simplified: route incoming packets to PIM or sequencer based on address
    always_comb begin
        local_out_ready = 1'b1;
        local_in_valid = 1'b0;
        local_in_data = '0;
        local_in_dest = '0;
        pim_valid = 1'b0;
        pim_cmd = 2'd0;
        pim_addr = '0;
        pim_wdata = '0;
        seq_run = 1'b0;
        seq_start_pc = '0;

        if (local_out_valid) begin
            // Decode packet: address bit 27 = 0 -> PIM, 1 -> sequencer config
            if (local_out_data[27] == 1'b0) begin
                pim_valid = 1'b1;
                pim_cmd = local_out_data[29:28];
                pim_addr = local_out_data[15:0];
                pim_wdata = local_out_data[DATA_W-1:0];
            end else begin
                seq_run = local_out_data[0];
                seq_start_pc = local_out_data[16:1];
            end
        end

        // Send PIM responses back to router
        if (pim_ready && pim_valid) begin
            local_in_valid = 1'b1;
            local_in_data = pim_rdata;
            local_in_dest = {tile_x, tile_y};  // Echo back to source (simplified)
        end
    end

    assign tile_busy = seq_busy;
    assign tile_done = seq_done;

endmodule
