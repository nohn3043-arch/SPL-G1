// ============================================================================
// spl_multi_tile_array — Scalable Multi-Tile SPL-G1 Array
// ============================================================================
// Parameterized 2D array of SPL-G1 tiles interconnected by a 2D mesh NoC.
// Supports configurations from 1x1 (256 PIM units) up to 64x64 (4096 tiles,
// 1,048,576 PIM units) for commercial deployment.
//
// REPAIRED + NoC IMPLEMENTED (2026-09-25):
//   - Port map no longer uses genvar ternaries (Icarus: "reference to a wire
//     or reg (`y') is not allowed in a constant expression").
//   - Status aggregation uses generate-flattened vectors (no variable
//     indexing into unpacked arrays inside always_*).
//   - INTER-TILE NoC IS NOW WIRED with EIGHT independent bus groups, i.e.
//     each direction gets its own send bus and its own receive bus.
//     The original revision drove both tile(k,x).south_out_* and
//     tile(k-1,x).north_out_* onto ONE net ns_*[k][x] (two drivers per net,
//     not realizable). Splitting send/receive removes the multi-driver
//     conflict and makes multi-hop forwarding well defined.
//
// Bus naming (all constant-indexed via generate):
//   Vertical   (y axis):
//     v_dn_*[k][x]  — packet entering tile(k,x) from ABOVE
//                     (driven by tile(k-1,x).south_out)
//     v_up_*[k][x]  — packet sent UP by tile(k,x)
//                     (consumed by tile(k-1,x).south_in)
//   Horizontal (x axis):
//     h_rt_*[y][k]  — packet entering tile(y,k) from the LEFT
//                     (driven by tile(y,k-1).east_out)
//     h_lt_*[y][k]  — packet sent LEFT by tile(y,k)
//                     (consumed by tile(y,k-1).east_in)
//   A `_r` suffix is the reverse-direction ready of the same link.
//
// Host attachment: host_valid/data/dest inject into tile(0,0).west_in, and
// tile(0,0).west_out returns via host_resp_*.
//
// NOTE: routing itself (XY) lives in spl_mesh_router; this module only
// provides the physical links. Buffering/credit flow control still pending.
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

    // ═══════════════════════════════════════════════════════════════════
    // Mesh link buses — 8 groups (4 directions x send/receive)
    // ═══════════════════════════════════════════════════════════════════
    // Vertical (rows+1 slots: index k = link between row k-1 and row k)
    logic              v_dn_v [0:TILE_ROWS][0:TILE_COLS-1];
    logic [DATA_W-1:0] v_dn_d [0:TILE_ROWS][0:TILE_COLS-1];
    logic [ADDR_W-1:0] v_dn_k [0:TILE_ROWS][0:TILE_COLS-1];
    logic              v_dn_r [0:TILE_ROWS][0:TILE_COLS-1];

    logic              v_up_v [0:TILE_ROWS][0:TILE_COLS-1];
    logic [DATA_W-1:0] v_up_d [0:TILE_ROWS][0:TILE_COLS-1];
    logic [ADDR_W-1:0] v_up_k [0:TILE_ROWS][0:TILE_COLS-1];
    logic              v_up_r [0:TILE_ROWS][0:TILE_COLS-1];

    // Horizontal (cols+1 slots: index k = link between col k-1 and col k)
    logic              h_rt_v [0:TILE_ROWS-1][0:TILE_COLS];
    logic [DATA_W-1:0] h_rt_d [0:TILE_ROWS-1][0:TILE_COLS];
    logic [ADDR_W-1:0] h_rt_k [0:TILE_ROWS-1][0:TILE_COLS];
    logic              h_rt_r [0:TILE_ROWS-1][0:TILE_COLS];

    logic              h_lt_v [0:TILE_ROWS-1][0:TILE_COLS];
    logic [DATA_W-1:0] h_lt_d [0:TILE_ROWS-1][0:TILE_COLS];
    logic [ADDR_W-1:0] h_lt_k [0:TILE_ROWS-1][0:TILE_COLS];
    logic              h_lt_r [0:TILE_ROWS-1][0:TILE_COLS];

    // ── Tile status ──
    logic tile_busy [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic tile_done [0:TILE_ROWS-1][0:TILE_COLS-1];

    // ═══════════════════════════════════════════════════════════════════
    // Boundary tie-offs (derive from boundary tiles / terminate at edges)
    // ═══════════════════════════════════════════════════════════════════
    generate
        for (genvar bx = 0; bx < TILE_COLS; bx = bx + 1) begin : gen_ns_edge
            // North edge: nothing arrives into row 0 from above.
            assign v_dn_v[0][bx] = 1'b0;
            assign v_dn_d[0][bx] = {DATA_W{1'b0}};
            assign v_dn_k[0][bx] = {ADDR_W{1'b0}};
            // South edge: last row's outward links terminate with ready.
            assign v_dn_r[TILE_ROWS][bx] = 1'b1;
            assign v_up_v[TILE_ROWS][bx] = 1'b0;
            assign v_up_d[TILE_ROWS][bx] = {DATA_W{1'b0}};
            assign v_up_k[TILE_ROWS][bx] = {ADDR_W{1'b0}};
            assign v_up_r[TILE_ROWS][bx] = 1'b1;
        end
    endgenerate

    generate
        for (genvar by2 = 0; by2 < TILE_ROWS; by2 = by2 + 1) begin : gen_ew_edge
            // East edge: rightmost column's eastward sends terminate with ready.
            assign h_rt_r[by2][TILE_COLS] = 1'b1;
        end
    endgenerate

    // West edge: column 0 receives from the host in row 0, else tied off.
    // h_lt_r[y][0] is the ready for tile(y,0).west_out (host consumes row 0).
    generate
        for (genvar by3 = 0; by3 < TILE_ROWS; by3 = by3 + 1) begin : gen_west_edge
            if (by3 == 0) begin : gen_host_in
                assign h_rt_v[0][0] = host_valid;
                assign h_rt_d[0][0] = host_data;
                assign h_rt_k[0][0] = host_dest;
                assign h_lt_r[0][0] = host_resp_ready;
            end else begin : gen_tie
                assign h_rt_v[by3][0] = 1'b0;
                assign h_rt_d[by3][0] = {DATA_W{1'b0}};
                assign h_rt_k[by3][0] = {ADDR_W{1'b0}};
                assign h_lt_r[by3][0] = 1'b1;
            end
        end
    endgenerate

    // ═══════════════════════════════════════════════════════════════════
    // Tile array with full mesh interconnect
    // ═══════════════════════════════════════════════════════════════════
    generate
        for (genvar y = 0; y < TILE_ROWS; y = y + 1) begin : gen_tile_row
            for (genvar x = 0; x < TILE_COLS; x = x + 1) begin : gen_tile_col
                spl_tile #(.DATA_W(DATA_W), .TILE_ADDR_W(ADDR_W)) u_tile (
                    .clk, .rst_n,
                    .tile_x(8'(x)), .tile_y(8'(y)),

                    // North: receive from above (v_dn[y]), send up (v_up[y])
                    .north_in_valid (v_dn_v[y][x]),
                    .north_in_data  (v_dn_d[y][x]),
                    .north_in_dest  (v_dn_k[y][x]),
                    .north_in_ready (v_dn_r[y][x]),
                    .north_out_valid(v_up_v[y][x]),
                    .north_out_data (v_up_d[y][x]),
                    .north_out_dest (v_up_k[y][x]),
                    .north_out_ready(v_up_r[y+1][x]),

                    // South: receive from below (v_up[y+1]), send down (v_dn[y+1])
                    .south_in_valid (v_up_v[y+1][x]),
                    .south_in_data  (v_up_d[y+1][x]),
                    .south_in_dest  (v_up_k[y+1][x]),
                    .south_in_ready (v_up_r[y][x]),
                    .south_out_valid(v_dn_v[y+1][x]),
                    .south_out_data (v_dn_d[y+1][x]),
                    .south_out_dest (v_dn_k[y+1][x]),
                    .south_out_ready(v_dn_r[y+1][x]),

                    // West: receive from left (h_rt[y]), send left (h_lt[y])
                    .west_in_valid  (h_rt_v[y][x]),
                    .west_in_data   (h_rt_d[y][x]),
                    .west_in_dest   (h_rt_k[y][x]),
                    .west_in_ready  (h_rt_r[y][x]),
                    .west_out_valid (h_lt_v[y][x]),
                    .west_out_data  (h_lt_d[y][x]),
                    .west_out_dest  (h_lt_k[y][x]),
                    .west_out_ready (h_lt_r[y][x]),

                    // East: receive from right (h_lt[y+1 col]), send right (h_rt[x+1])
                    .east_in_valid  (h_lt_v[y][x+1]),
                    .east_in_data   (h_lt_d[y][x+1]),
                    .east_in_dest   (h_lt_k[y][x+1]),
                    .east_in_ready  (h_lt_r[y][x+1]),
                    .east_out_valid (h_rt_v[y][x+1]),
                    .east_out_data  (h_rt_d[y][x+1]),
                    .east_out_dest  (h_rt_k[y][x+1]),
                    .east_out_ready (h_rt_r[y][x+1]),

                    // ── Global broadcast config ──
                    .cfg_valid      (global_run),
                    .cfg_data       ({112'd0, global_start_pc}),
                    .tile_busy      (tile_busy[y][x]),
                    .tile_done      (tile_done[y][x])
                );
            end
        end
    endgenerate

    // ═══════════════════════════════════════════════════════════════════
    // Host response path (tile(0,0).west_out → host)
    // ═══════════════════════════════════════════════════════════════════
    assign host_ready      = h_rt_r[0][0];
    assign host_resp_valid = h_lt_v[0][0];
    assign host_resp_data  = h_lt_d[0][0];

    // ═══════════════════════════════════════════════════════════════════
    // Global status aggregation (generate-flattened; no variable indexing)
    // ═══════════════════════════════════════════════════════════════════
    logic [TILE_ROWS*TILE_COLS-1:0] busy_flat;
    logic [TILE_ROWS*TILE_COLS-1:0] done_flat;

    generate
        for (genvar gy = 0; gy < TILE_ROWS; gy = gy + 1) begin : gen_flat_row
            for (genvar gx = 0; gx < TILE_COLS; gx = gx + 1) begin : gen_flat_col
                assign busy_flat[gy*TILE_COLS+gx] = tile_busy[gy][gx];
                assign done_flat[gy*TILE_COLS+gx] = tile_done[gy][gx];
            end
        end
    endgenerate

    assign all_busy = |busy_flat;
    assign all_done = &done_flat;

endmodule
