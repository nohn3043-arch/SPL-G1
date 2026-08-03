// ============================================================================
// G1_Commercial_Top — SPL-G1 Commercial Edition Top-Level
// ============================================================================
// D-phase commercial implementation: 64x64 tile array = 4096 tiles =
// 1,048,576 PIM compute units, 16MB total on-chip SRAM, PCIe Gen5 x16 / CXL 2.0
// host interface, 2D Mesh NoC interconnect.
//
// Scaling parameters:
//   - TILE_ROWS/COLS: Adjust to scale array size (1x1 to 64x64)
//   - 64x64 configuration: 1M+ PIM units, 16MB on-chip SRAM, ~256 TOPS @ 1GHz
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module G1_Commercial_Top #(
    parameter int TILE_ROWS  = 64,    // 64x64 = 4096 tiles = 1M PIM units
    parameter int TILE_COLS  = 64,
    parameter int DATA_W     = 128,
    parameter int ADDR_W     = 16
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ── PCIe/CXL interface ──
    input  logic                        pcie_rx_valid,
    input  logic [DATA_W-1:0]           pcie_rx_data,
    input  logic [3:0]                  pcie_rx_type,
    input  logic [63:0]                 pcie_rx_addr,
    input  logic [15:0]                 pcie_rx_req_id,
    output logic                        pcie_tx_valid,
    output logic [DATA_W-1:0]           pcie_tx_data,
    output logic [3:0]                  pcie_tx_type,
    output logic [15:0]                 pcie_tx_req_id,
    input  logic                        pcie_tx_ready,

    // ── Interrupt output ──
    output logic                        irq,

    // ── DRAM interface (AXI4) ──
    output logic                        dram_awvalid,
    input  logic                        dram_awready,
    output logic [31:0]                 dram_awaddr,
    output logic [7:0]                  dram_awlen,
    output logic                        dram_wvalid,
    input  logic                        dram_wready,
    output logic [511:0]                dram_wdata,
    output logic [63:0]                 dram_wstrb,
    output logic                        dram_wlast,
    input  logic                        dram_bvalid,
    output logic                        dram_bready,
    output logic                        dram_arvalid,
    input  logic                        dram_arready,
    output logic [31:0]                 dram_araddr,
    output logic [7:0]                  dram_arlen,
    input  logic                        dram_rvalid,
    output logic                        dram_rready,
    input  logic [511:0]                dram_rdata,
    input  logic                        dram_rlast
);

    // ── Internal signals between host IF and tile array ──
    logic                        host_valid;
    logic [DATA_W-1:0]           host_data;
    logic [ADDR_W-1:0]           host_dest;
    logic                        host_ready;
    logic                        host_resp_valid;
    logic [DATA_W-1:0]           host_resp_data;
    logic                        host_resp_ready;
    logic                        global_run;
    logic [15:0]                 global_start_pc;
    logic                        all_busy;
    logic                        all_done;

    // ── PCIe/CXL Host Interface ──
    pcie_cxl_host_if #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) u_host_if (
        .clk, .rst_n,
        .pcie_rx_valid, .pcie_rx_data, .pcie_rx_type, .pcie_rx_addr, .pcie_rx_req_id,
        .pcie_tx_valid, .pcie_tx_data, .pcie_tx_type, .pcie_tx_req_id, .pcie_tx_ready,
        .tile_valid(host_valid), .tile_data(host_data), .tile_dest(host_dest),
        .tile_ready(host_ready), .tile_resp_valid(host_resp_valid),
        .tile_resp_data(host_resp_data), .tile_resp_ready(host_resp_ready),
        .global_run, .global_start_pc, .all_busy, .all_done, .irq
    );

    // ── Multi-Tile Compute Array ──
    spl_multi_tile_array #(
        .TILE_ROWS(TILE_ROWS), .TILE_COLS(TILE_COLS),
        .DATA_W(DATA_W), .ADDR_W(ADDR_W)
    ) u_tile_array (
        .clk, .rst_n,
        .host_valid, .host_data, .host_dest, .host_ready,
        .host_resp_valid, .host_resp_data, .host_resp_ready,
        .global_run, .global_start_pc, .all_busy, .all_done
    );

    // ── DRAM controller (integrated in future phase; tie off for now) ──
    assign dram_awvalid = 1'b0;
    assign dram_awaddr  = '0;
    assign dram_awlen   = '0;
    assign dram_wvalid  = 1'b0;
    assign dram_wdata   = '0;
    assign dram_wstrb   = '0;
    assign dram_wlast   = 1'b0;
    assign dram_bready  = 1'b1;
    assign dram_arvalid = 1'b0;
    assign dram_araddr  = '0;
    assign dram_arlen   = '0;
    assign dram_rready  = 1'b1;

endmodule
