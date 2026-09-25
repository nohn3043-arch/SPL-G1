// ============================================================================
// spl_mesh_router — 2D Mesh NoC Router for SPL-G1 Multi-Tile Array
// ============================================================================
// 5-port router: North, South, East, West, Local (to PIM tile)
// XY dimension-order routing.
//
// REWRITTEN (interface repair follow-up):
//   - Previous revision used variable-index access into unpacked arrays
//     inside always_* (`ibuf_dest[in_p][0][ibuf_head[in_p]]`) → Icarus
//     rejects it ("Array ... needs 2 indices" / constant-select errors).
//     Its buffer bookkeeping was also incomplete (ibuf_full never updated,
//     no head/tail wraparound), so it could not elaborate at all.
//   - This revision is a COMBINATIONAL single-cycle XY router with a
//     fixed-priority output arbiter (LOCAL > NORTH > SOUTH > EAST > WEST).
//   - ADDED: `*_out_dest` outputs. A mesh packet MUST carry its destination
//     coordinate to be routable at the next hop; the old port set exposed
//     only data/valid/ready, which made multi-hop forwarding impossible
//     and caused spl_multi_tile_array to reference non-existent ports.
//
// No packet buffering yet — NUM_VC / BUFFER_DEPTH are retained for interface
// compatibility only. Credit-based flow control is an open follow-up.
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_mesh_router #(
    parameter int DATA_W     = 128,
    parameter int ADDR_W     = 16,   // 8bit X + 8bit Y coordinate
    parameter int NUM_VC     = 2,    // reserved (no VC implementation yet)
    parameter int BUFFER_DEPTH = 4   // reserved (combinational passthrough)
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ── Local port (to PIM tile) ──
    input  logic                        local_in_valid,
    input  logic [DATA_W-1:0]           local_in_data,
    input  logic [ADDR_W-1:0]           local_in_dest,
    output logic                        local_in_ready,
    output logic                        local_out_valid,
    output logic [DATA_W-1:0]           local_out_data,
    output logic [ADDR_W-1:0]           local_out_dest,
    input  logic                        local_out_ready,

    // ── North port ──
    input  logic                        north_in_valid,
    input  logic [DATA_W-1:0]           north_in_data,
    input  logic [ADDR_W-1:0]           north_in_dest,
    output logic                        north_in_ready,
    output logic                        north_out_valid,
    output logic [DATA_W-1:0]           north_out_data,
    output logic [ADDR_W-1:0]           north_out_dest,
    input  logic                        north_out_ready,

    // ── South port ──
    input  logic                        south_in_valid,
    input  logic [DATA_W-1:0]           south_in_data,
    input  logic [ADDR_W-1:0]           south_in_dest,
    output logic                        south_in_ready,
    output logic                        south_out_valid,
    output logic [DATA_W-1:0]           south_out_data,
    output logic [ADDR_W-1:0]           south_out_dest,
    input  logic                        south_out_ready,

    // ── East port ──
    input  logic                        east_in_valid,
    input  logic [DATA_W-1:0]           east_in_data,
    input  logic [ADDR_W-1:0]           east_in_dest,
    output logic                        east_in_ready,
    output logic                        east_out_valid,
    output logic [DATA_W-1:0]           east_out_data,
    output logic [ADDR_W-1:0]           east_out_dest,
    input  logic                        east_out_ready,

    // ── West port ──
    input  logic                        west_in_valid,
    input  logic [DATA_W-1:0]           west_in_data,
    input  logic [ADDR_W-1:0]           west_in_dest,
    output logic                        west_in_ready,
    output logic                        west_out_valid,
    output logic [DATA_W-1:0]           west_out_data,
    output logic [ADDR_W-1:0]           west_out_dest,
    input  logic                        west_out_ready,

    // ── Router coordinate ──
    input  logic [7:0]                  my_x,
    input  logic [7:0]                  my_y
);

    // ── Port enumeration ──
    typedef enum logic [2:0] {
        PORT_LOCAL = 3'd0,
        PORT_NORTH = 3'd1,
        PORT_SOUTH = 3'd2,
        PORT_EAST  = 3'd3,
        PORT_WEST  = 3'd4
    } port_t;

    // ── XY dimension-order routing ──
    // X first, then Y; arriving at own coordinate → LOCAL (eject).
    function automatic port_t route(input logic [7:0] dest_x,
                                    input logic [7:0] dest_y);
        if (dest_x < my_x) return PORT_WEST;
        if (dest_x > my_x) return PORT_EAST;
        if (dest_y < my_y) return PORT_NORTH;
        if (dest_y > my_y) return PORT_SOUTH;
        return PORT_LOCAL;
    endfunction

    // ── Per-input routing decision (constant-indexed) ──
    port_t sel_local, sel_north, sel_south, sel_east, sel_west;

    assign sel_local = route(local_in_dest[15:8], local_in_dest[7:0]);
    assign sel_north = route(north_in_dest[15:8], north_in_dest[7:0]);
    assign sel_south = route(south_in_dest[15:8], south_in_dest[7:0]);
    assign sel_east  = route(east_in_dest[15:8],  east_in_dest[7:0]);
    assign sel_west  = route(west_in_dest[15:8],  west_in_dest[7:0]);

    // clk/rst_n unused in the combinational implementation; referenced to
    // avoid dangling-port warnings.
    logic unused_ok;
    assign unused_ok = clk & rst_n;

    // ── Output arbitration (fixed priority: LOCAL > NORTH > SOUTH > EAST > WEST) ──
    // Each output port forwards the highest-priority input whose route targets
    // it, including that packet's destination coordinate.
    always_comb begin
        // ── defaults ──
        local_out_valid = 1'b0; local_out_data = {DATA_W{1'b0}}; local_out_dest = {ADDR_W{1'b0}};
        north_out_valid = 1'b0; north_out_data = {DATA_W{1'b0}}; north_out_dest = {ADDR_W{1'b0}};
        south_out_valid = 1'b0; south_out_data = {DATA_W{1'b0}}; south_out_dest = {ADDR_W{1'b0}};
        east_out_valid  = 1'b0; east_out_data  = {DATA_W{1'b0}}; east_out_dest  = {ADDR_W{1'b0}};
        west_out_valid  = 1'b0; west_out_data  = {DATA_W{1'b0}}; west_out_dest  = {ADDR_W{1'b0}};

        // ══ LOCAL output ══
        if (local_in_valid && sel_local == PORT_LOCAL) begin
            local_out_valid = 1'b1; local_out_data = local_in_data; local_out_dest = local_in_dest;
        end else if (north_in_valid && sel_north == PORT_LOCAL) begin
            local_out_valid = 1'b1; local_out_data = north_in_data; local_out_dest = north_in_dest;
        end else if (south_in_valid && sel_south == PORT_LOCAL) begin
            local_out_valid = 1'b1; local_out_data = south_in_data; local_out_dest = south_in_dest;
        end else if (east_in_valid && sel_east == PORT_LOCAL) begin
            local_out_valid = 1'b1; local_out_data = east_in_data; local_out_dest = east_in_dest;
        end else if (west_in_valid && sel_west == PORT_LOCAL) begin
            local_out_valid = 1'b1; local_out_data = west_in_data; local_out_dest = west_in_dest;
        end

        // ══ NORTH output ══
        if (local_in_valid && sel_local == PORT_NORTH) begin
            north_out_valid = 1'b1; north_out_data = local_in_data; north_out_dest = local_in_dest;
        end else if (north_in_valid && sel_north == PORT_NORTH) begin
            north_out_valid = 1'b1; north_out_data = north_in_data; north_out_dest = north_in_dest;
        end else if (south_in_valid && sel_south == PORT_NORTH) begin
            north_out_valid = 1'b1; north_out_data = south_in_data; north_out_dest = south_in_dest;
        end else if (east_in_valid && sel_east == PORT_NORTH) begin
            north_out_valid = 1'b1; north_out_data = east_in_data; north_out_dest = east_in_dest;
        end else if (west_in_valid && sel_west == PORT_NORTH) begin
            north_out_valid = 1'b1; north_out_data = west_in_data; north_out_dest = west_in_dest;
        end

        // ══ SOUTH output ══
        if (local_in_valid && sel_local == PORT_SOUTH) begin
            south_out_valid = 1'b1; south_out_data = local_in_data; south_out_dest = local_in_dest;
        end else if (north_in_valid && sel_north == PORT_SOUTH) begin
            south_out_valid = 1'b1; south_out_data = north_in_data; south_out_dest = north_in_dest;
        end else if (south_in_valid && sel_south == PORT_SOUTH) begin
            south_out_valid = 1'b1; south_out_data = south_in_data; south_out_dest = south_in_dest;
        end else if (east_in_valid && sel_east == PORT_SOUTH) begin
            south_out_valid = 1'b1; south_out_data = east_in_data; south_out_dest = east_in_dest;
        end else if (west_in_valid && sel_west == PORT_SOUTH) begin
            south_out_valid = 1'b1; south_out_data = west_in_data; south_out_dest = west_in_dest;
        end

        // ══ EAST output ══
        if (local_in_valid && sel_local == PORT_EAST) begin
            east_out_valid = 1'b1; east_out_data = local_in_data; east_out_dest = local_in_dest;
        end else if (north_in_valid && sel_north == PORT_EAST) begin
            east_out_valid = 1'b1; east_out_data = north_in_data; east_out_dest = north_in_dest;
        end else if (south_in_valid && sel_south == PORT_EAST) begin
            east_out_valid = 1'b1; east_out_data = south_in_data; east_out_dest = south_in_dest;
        end else if (east_in_valid && sel_east == PORT_EAST) begin
            east_out_valid = 1'b1; east_out_data = east_in_data; east_out_dest = east_in_dest;
        end else if (west_in_valid && sel_west == PORT_EAST) begin
            east_out_valid = 1'b1; east_out_data = west_in_data; east_out_dest = west_in_dest;
        end

        // ══ WEST output ══
        if (local_in_valid && sel_local == PORT_WEST) begin
            west_out_valid = 1'b1; west_out_data = local_in_data; west_out_dest = local_in_dest;
        end else if (north_in_valid && sel_north == PORT_WEST) begin
            west_out_valid = 1'b1; west_out_data = north_in_data; west_out_dest = north_in_dest;
        end else if (south_in_valid && sel_south == PORT_WEST) begin
            west_out_valid = 1'b1; west_out_data = south_in_data; west_out_dest = south_in_dest;
        end else if (east_in_valid && sel_east == PORT_WEST) begin
            west_out_valid = 1'b1; west_out_data = east_in_data; west_out_dest = east_in_dest;
        end else if (west_in_valid && sel_west == PORT_WEST) begin
            west_out_valid = 1'b1; west_out_data = west_in_data; west_out_dest = west_in_dest;
        end
    end

    // ── Input ready ──
    // Combinational passthrough: no buffering, so a port can always accept.
    // (Backpressure / credit flow control arrives with buffering.)
    assign local_in_ready = 1'b1;
    assign north_in_ready = 1'b1;
    assign south_in_ready = 1'b1;
    assign east_in_ready  = 1'b1;
    assign west_in_ready  = 1'b1;

endmodule
