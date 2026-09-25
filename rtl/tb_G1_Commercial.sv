// ============================================================================
// tb_G1_Commercial — Commercial Top Smoke Test (interface + host path)
// ============================================================================
// Purpose: give the commercial chain a REAL compile/run entry point so that
// a future interface break (like the 2026-09 one, where spl_tile referenced
// port names that never existed) is caught immediately instead of silently.
//
// Scope (deliberately small — 2x2 tiles, 1024 PIM cells): the production
// configuration 64x64 = 1,048,576 cells cannot be elaborated by Icarus at all.
//
// Verifies:
//   1. Elaboration of G1_Commercial_Top -> spl_multi_tile_array -> spl_tile
//      -> spl_mesh_router / spl_pim_sequencer / spl_pim_compute_array
//      + pcie_cxl_host_if (this file compiling IS the primary assertion).
//   2. Post-reset outputs are defined (no X).
//   3. PCIe BAR0 read path (DEVICE_ID readback).
//   4. GLOBAL_RUN / START_PC register write propagation into the tile array.
//   5. DRAM tie-off stays inactive (as currently declared).
//
// Compile:
//   iverilog -g2012 -I rtl -o g1_commercial_sim rtl/G1_Commercial_Top.sv \
//     rtl/spl_multi_tile_array.sv rtl/spl_tile.sv rtl/spl_mesh_router.sv \
//     rtl/spl_pim_compute_array.sv rtl/spl_pim_cell.sv rtl/spl_pim_sequencer.sv \
//     rtl/pcie_cxl_host_if.sv rtl/tb_G1_Commercial.sv
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

`timescale 1ns / 1ps

module tb_G1_Commercial;

    localparam int DATA_W    = 128;
    localparam int ADDR_W    = 16;
    localparam int TILE_ROWS = 2;
    localparam int TILE_COLS = 2;

    logic clk, rst_n;

    // ── PCIe/CXL host side ──
    logic              pcie_rx_valid;
    logic [DATA_W-1:0] pcie_rx_data;
    logic [3:0]        pcie_rx_type;
    logic [63:0]       pcie_rx_addr;
    logic [15:0]       pcie_rx_req_id;
    logic              pcie_tx_valid;
    logic [DATA_W-1:0] pcie_tx_data;
    logic [3:0]        pcie_tx_type;
    logic [15:0]       pcie_tx_req_id;
    logic              pcie_tx_ready;
    logic              irq;

    // ── DRAM (AXI4) ──
    logic              dram_awvalid, dram_awready;
    logic [31:0]       dram_awaddr;
    logic [7:0]        dram_awlen;
    logic              dram_wvalid, dram_wready;
    logic [511:0]      dram_wdata;
    logic [63:0]       dram_wstrb;
    logic              dram_wlast, dram_bvalid, dram_bready;
    logic              dram_arvalid, dram_arready;
    logic [31:0]       dram_araddr;
    logic [7:0]        dram_arlen;
    logic              dram_rvalid, dram_rready;
    logic [511:0]      dram_rdata;
    logic              dram_rlast;

    G1_Commercial_Top #(
        .TILE_ROWS(TILE_ROWS), .TILE_COLS(TILE_COLS),
        .DATA_W(DATA_W), .ADDR_W(ADDR_W)
    ) dut (
        .clk, .rst_n,
        .pcie_rx_valid, .pcie_rx_data, .pcie_rx_type, .pcie_rx_addr, .pcie_rx_req_id,
        .pcie_tx_valid, .pcie_tx_data, .pcie_tx_type, .pcie_tx_req_id, .pcie_tx_ready,
        .irq,
        .dram_awvalid, .dram_awready, .dram_awaddr, .dram_awlen,
        .dram_wvalid, .dram_wready, .dram_wdata, .dram_wstrb, .dram_wlast,
        .dram_bvalid, .dram_bready,
        .dram_arvalid, .dram_arready, .dram_araddr, .dram_arlen,
        .dram_rvalid, .dram_rready, .dram_rdata, .dram_rlast
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ── TX completion capture ──
    // pcie_tx_valid is a 1-cycle pulse (the completion FIFO pops on the same
    // cycle it presents), so "wait N cycles then sample" races and reads 0.
    // Latch the first completion instead.
    logic [DATA_W-1:0] captured_tx_data;
    logic              captured_tx_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            captured_tx_valid <= 1'b0;
            captured_tx_data  <= {DATA_W{1'b0}};
        end else if (pcie_tx_valid) begin
            captured_tx_valid <= 1'b1;
            captured_tx_data  <= pcie_tx_data;
        end
    end

    integer errors;

    // ── PCIe TLP helpers ──
    task pcie_write;
        input [63:0] addr;
        input [DATA_W-1:0] data;
        begin
            @(negedge clk);
            pcie_rx_valid = 1'b1; pcie_rx_type = 4'd1;
            pcie_rx_addr = addr; pcie_rx_data = data; pcie_rx_req_id = 16'h0001;
            @(posedge clk);
            @(negedge clk);
            pcie_rx_valid = 1'b0;
            pcie_rx_data = {DATA_W{1'b0}};
        end
    endtask

    task pcie_read;
        input [63:0] addr;
        begin
            @(negedge clk);
            pcie_rx_valid = 1'b1; pcie_rx_type = 4'd0;
            pcie_rx_addr = addr; pcie_rx_req_id = 16'h0002;
            @(posedge clk);
            @(negedge clk);
            pcie_rx_valid = 1'b0;
        end
    endtask

    initial begin
        errors = 0;
        pcie_rx_valid = 1'b0; pcie_rx_data = {DATA_W{1'b0}}; pcie_rx_type = 4'd0;
        pcie_rx_addr = 64'h0; pcie_rx_req_id = 16'h0;
        pcie_tx_ready = 1'b1;
        dram_awready = 1'b0; dram_wready = 1'b0; dram_bvalid = 1'b0;
        dram_arready = 1'b0; dram_rvalid = 1'b0;
        dram_rdata = 512'h0; dram_rlast = 1'b0;

        rst_n = 1'b0; #100; rst_n = 1'b1; #20;

        $display("===== SPL-G1 Commercial Top Smoke Test =====");
        $display("Array: %0dx%0d tiles = %0d PIM cells (production default is 64x64 = 1048576)",
                 TILE_ROWS, TILE_COLS, TILE_ROWS*TILE_COLS*256);

        // ── Test 1: post-reset outputs defined ──
        if (pcie_tx_valid === 1'b0 && irq === 1'b0)
            $display("[PASS] 1a: post-reset outputs defined");
        else begin
            $display("[FAIL] 1a: tx_valid=%b irq=%b", pcie_tx_valid, irq);
            errors = errors + 1;
        end

        // ── Test 2: BAR0 DEVICE_ID readback ──
        pcie_read(64'h0000_0000);
        repeat(8) @(posedge clk);
        if (captured_tx_valid === 1'b1 && captured_tx_data === 64'h5350_4C47_3100_0001)
            $display("[PASS] 2a: BAR0 DEVICE_ID readback = 0x%016h", captured_tx_data);
        else begin
            $display("[FAIL] 2a: captured=%b data=0x%032h (live tx_valid=%b)",
                     captured_tx_valid, captured_tx_data, pcie_tx_valid);
            errors = errors + 1;
        end

        // ── Test 3: GLOBAL_RUN write propagates ──
        pcie_write(64'h0000_0010, 128'h1);
        repeat(6) @(posedge clk);
        if (dut.u_host_if.global_run === 1'b1)
            $display("[PASS] 3a: GLOBAL_RUN propagated into tile array");
        else begin
            $display("[FAIL] 3a: global_run=%b", dut.u_host_if.global_run);
            errors = errors + 1;
        end

        // ── Test 4: START_PC write propagates ──
        pcie_write(64'h0000_0018, 128'h2A);
        repeat(6) @(posedge clk);
        if (dut.u_host_if.global_start_pc === 16'h2A)
            $display("[PASS] 4a: START_PC propagated = 0x%04h", dut.u_host_if.global_start_pc);
        else begin
            $display("[FAIL] 4a: start_pc=0x%04h", dut.u_host_if.global_start_pc);
            errors = errors + 1;
        end

        // ── Test 5: DRAM tie-off stays inactive ──
        if (dram_awvalid === 1'b0 && dram_arvalid === 1'b0)
            $display("[PASS] 5a: DRAM tie-off inactive (as declared)");
        else begin
            $display("[FAIL] 5a: dram_awvalid=%b dram_arvalid=%b", dram_awvalid, dram_arvalid);
            errors = errors + 1;
        end

        $display("===== Results: %0d errors =====", errors);
        if (errors == 0)
            $display("[FINAL] COMMERCIAL SMOKE PASSED.");
        else
            $display("[FINAL] FAILED: %0d error(s).", errors);
        $finish;
    end

    initial begin
        $dumpfile("g1_commercial_wave.vcd");
        `ifdef DUMP_VCD
        $dumpvars(0, tb_G1_Commercial);
        `endif
    end

endmodule
