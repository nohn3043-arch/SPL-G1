// ============================================================================
// spl_multi_tile_array — Scalable Multi-Tile SPL-G1 Array
// ============================================================================
// Parameterized 2D array of SPL-G1 tiles connected via Mesh NoC.
// Supports configurations from 1x1 (256 PIM units) up to 64x64 (4096 tiles,
// 1,048,576 PIM units = 16MB total on-chip SRAM) for commercial deployment.
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_multi_tile_array #(
    parameter int TILE_ROWS  = 8,    // Default 8x8 = 64 tiles = 16384 PIM units
    parameter int TILE_COLS  = 8,
    parameter int DATA_W     = 128,
    parameter int ADDR_W     = 16    // 8bit X + 8bit Y
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ── Host interface (PCIe/CXL) ──
    input  logic                        host_valid,
    input  logic [DATA_W-1:0]           host_data,
    input  logic [ADDR_W-1:0]           host_dest,
    output logic                        host_ready,
    output logic                        host_resp_valid,
    output logic [DATA_W-1:0]           host_resp_data,
    input  logic                        host_resp_ready,

    // ── Global control ──
    input  logic                        global_run,
    input  logic [15:0]                 global_start_pc,
    output logic                        all_busy,
    output logic                        all_done
);

    // ── Inter-tile Mesh connections ──
    // North/South connections: [tile_y][tile_x]
    logic [DATA_W-1:0] ns_data  [0:TILE_ROWS][0:TILE_COLS-1];
    logic              ns_valid [0:TILE_ROWS][0:TILE_COLS-1];
    logic [ADDR_W-1:0] ns_dest  [0:TILE_ROWS][0:TILE_COLS-1];
    logic              ns_ready [0:TILE_ROWS][0:TILE_COLS-1];

    // East/West connections: [tile_y][tile_x]
    logic [DATA_W-1:0] ew_data  [0:TILE_ROWS-1][0:TILE_COLS];
    logic              ew_valid [0:TILE_ROWS-1][0:TILE_COLS];
    logic [ADDR_W-1:0] ew_dest  [0:TILE_ROWS-1][0:TILE_COLS];
    logic              ew_ready [0:TILE_ROWS-1][0:TILE_COLS];

    // Tile status signals
    logic tile_busy [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic tile_done [0:TILE_ROWS-1][0:TILE_COLS-1];

    // ── Generate tile array ──
    generate
        for (genvar y = 0; y < TILE_ROWS; y = y + 1) begin : gen_tile_row
            for (genvar x = 0; x < TILE_COLS; x = x + 1) begin : gen_tile_col
                spl_tile #(.DATA_W(DATA_W), .TILE_ADDR_W(ADDR_W)) u_tile (
                    .clk, .rst_n,
                    .tile_x(8'(x)), .tile_y(8'(y)),

                    // North port: connect to south port of tile above, or tie off at top edge
                    .north_in_valid  (y == 0 ? 1'b0 : ns_valid[y][x]),
                    .north_in_data   (y == 0 ? '0   : ns_data[y][x]),
                    .north_in_dest   (y == 0 ? '0   : ns_dest[y][x]),
                    .north_in_ready  (ns_ready[y][x]),
                    .north_out_valid (ns_valid[y+1][x]),
                    .north_out_data  (ns_data[y+1][x]),
                    .north_out_dest  (ns_dest[y+1][x]),
                    .north_out_ready (y == TILE_ROWS-1 ? 1'b1 : ns_ready[y+1][x]),

                    // South port: connect to north port of tile below, or tie off at bottom edge
                    .south_in_valid  (y == TILE_ROWS-1 ? 1'b0 : ns_valid[y+1][x]),
                    .south_in_data   (y == TILE_ROWS-1 ? '0   : ns_data[y+1][x]),
                    .south_in_dest   (y == TILE_ROWS-1 ? '0   : ns_dest[y+1][x]),
                    .south_in_ready  (ns_ready[y+1][x]),
                    .south_out_valid (ns_valid[y][x]),
                    .south_out_data  (ns_data[y][x]),
                    .south_out_dest  (ns_dest[y][x]),
                    .south_out_ready (y == 0 ? 1'b1 : ns_ready[y][x]),

                    // West port: connect to east port of tile to left, or host at (0,0)
                    .west_in_valid   (x == 0 ? (y == 0 ? host_valid : 1'b0) : ew_valid[y][x]),
                    .west_in_data    (x == 0 ? (y == 0 ? host_data : '0) : ew_data[y][x]),
                    .west_in_dest    (x == 0 ? (y == 0 ? host_dest : '0) : ew_dest[y][x]),
                    .west_in_ready   (x == 0 ? (y == 0 ? host_ready : 1'b0) : ew_ready[y][x]),
                    .west_out_valid  (ew_valid[y][x+1]),
                    .west_out_data   (ew_data[y][x+1]),
                    .west_out_dest   (ew_dest[y][x+1]),
                    .west_out_ready  (x == TILE_COLS-1 ? 1'b1 : ew_ready[y][x+1]),

                    // East port: connect to west port of tile to right, or tie off at right edge
                    .east_in_valid   (x == TILE_COLS-1 ? 1'b0 : ew_valid[y][x+1]),
                    .east_in_data    (x == TILE_COLS-1 ? '0   : ew_data[y][x+1]),
                    .east_in_dest    (x == TILE_COLS-1 ? '0   : ew_dest[y][x+1]),
                    .east_in_ready   (ew_ready[y][x+1]),
                    .east_out_valid  (ew_valid[y][x]),
                    .east_out_data   (ew_data[y][x]),
                    .east_out_dest   (ew_dest[y][x]),
                    .east_out_ready  (x == 0 ? (y == 0 ? host_resp_ready : 1'b1) : ew_ready[y][x]),

                    // Configuration: broadcast to all tiles
                    .cfg_valid(global_run),
                    .cfg_data({112'd0, global_start_pc}),
                    .tile_busy(tile_busy[y][x]),
                    .tile_done(tile_done[y][x])
                );
            end
        end
    endgenerate

    // ── Global status aggregation ──
    always_comb begin
        all_busy = 1'b0;
        all_done = 1'b1;
        for (int y = 0; y < TILE_ROWS; y++) begin
            for (int x = 0; x < TILE_COLS; x++) begin
                all_busy |= tile_busy[y][x];
                all_done &= tile_done[y][x];
            end
        end
    end

    // ── Host response: route responses from (0,0) east port back to host ──
    assign host_resp_valid = ew_valid[0][0];
    assign host_resp_data  = ew_data[0][0];

endmodule
