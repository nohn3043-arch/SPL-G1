// ============================================================================
// tb_materica_compliance — Unit Testbench for materica_compliance_unit_v2
// ============================================================================
// v2: packed ports + OOB-based PIM proximity detection
// Tests:
//   1. Full compliance baseline
//   2. Materica #1: phase violation (spontaneous flip under NOP)
//   3. Materica #2: directional violation (multi-target WRITE)
//   4. Materica #3: PIM proximity violation (OOB address = plane breach)
//   5. Materica #4: SBC physical attack (temperature)
//   6. Materica #4: SBC irreversibility (boundary loss latches)
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

`timescale 1ns / 1ps

module tb_materica_compliance;

    localparam int CELL_ROWS = 4;
    localparam int CELL_COLS = 4;
    localparam int PHASE_WINDOW = 16;
    localparam int DIR_THRESH   = 3;

    logic        clk = 0, rst_n;

    // PACKED cell vectors (v2): [ROWS*COLS*W-1:0]
    logic [CELL_ROWS*CELL_COLS*64-1:0] cell_states_packed;
    logic [CELL_ROWS*CELL_COLS*5 -1:0] cell_ops_packed;

    logic        ra_transaction_active;
    logic [ 3:0] ra_source_id, ra_target_id;
    logic [ 1:0] ra_direction;
    logic [31:0] ra_addr;
    logic        phys_temp_alarm, phys_volt_alarm, phys_rad_alarm, sec_boundary_intact;
    logic        materica_compliant;
    logic [ 3:0] compliance_status;
    logic        fuse_trigger;

    integer      test_pass, test_fail, test_total;

    // ── Pack cell (r,c) value into packed vector ──
    function automatic void pack_cell_state(input integer r, input integer c, input [63:0] val);
        cell_states_packed[((r*CELL_COLS+c)+1)*64-1 -: 64] = val;
    endfunction
    function automatic void pack_cell_op(input integer r, input integer c, input [4:0] val);
        cell_ops_packed[((r*CELL_COLS+c)+1)*5 -1 -: 5] = val;
    endfunction

    materica_compliance_unit #(
        .CELL_ROWS(CELL_ROWS),
        .CELL_COLS(CELL_COLS),
        .PHASE_WINDOW(PHASE_WINDOW),
        .DIR_VIOLATION_THRESH(DIR_THRESH)
    ) u_dut (
        .clk, .rst_n,
        .cell_states_packed, .cell_ops_packed,
        .ra_transaction_active, .ra_source_id, .ra_target_id, .ra_direction,
        .ra_addr,
        .phys_temp_alarm, .phys_volt_alarm, .phys_rad_alarm, .sec_boundary_intact,
        .materica_compliant, .compliance_status, .fuse_trigger
    );

    always #5 clk = ~clk;

    task reset_all;
        integer i, j;
        begin
            rst_n = 0;
            ra_transaction_active = 0; ra_source_id = 0; ra_target_id = 0; ra_direction = 0;
            ra_addr = 32'd0;
            phys_temp_alarm = 0; phys_volt_alarm = 0; phys_rad_alarm = 0; sec_boundary_intact = 1;
            cell_states_packed = '0;
            cell_ops_packed = '0;
            for (i = 0; i < CELL_ROWS; i = i + 1)
                for (j = 0; j < CELL_COLS; j = j + 1)
                    pack_cell_state(i, j, {8'd0, 8'd0, 16'd0, 16'd0, 16'd0});  // stable init
            #20 rst_n = 1; #10;
        end
    endtask

    task check;
        input [256*8-1:0] desc;
        input logic expected;
        begin
            #10;
            test_total = test_total + 1;
            if (materica_compliant === expected) begin
                test_pass = test_pass + 1;
                $display("[PASS] %0s", desc);
            end else begin
                test_fail = test_fail + 1;
                $display("[FAIL] %0s — expected compliant=%b got %b (status=%b)",
                         desc, expected, materica_compliant, compliance_status);
            end
        end
    endtask

    initial begin
        test_pass = 0; test_fail = 0; test_total = 0;

        // ═══════════════════════════════════════════
        // Test 1: Full Compliance
        // ═══════════════════════════════════════════
        $display("=== Test 1: Full Compliance ===");
        reset_all();
        repeat(20) @(posedge clk);
        check("Full compliance - all four Materica requirements met", 1'b1);

        // ═══════════════════════════════════════════
        // Test 2: Materica #1 FAIL — Phase Violation
        // ═══════════════════════════════════════════
        $display("=== Test 2: Materica #1 - Binary Phase Violation ===");
        reset_all();
        repeat(10) @(posedge clk);
        // Spontaneous flips under NOP: toggle cell(0,0) repeatedly
        repeat(20) begin
            @(posedge clk);
            pack_cell_state(0, 0, cell_states_packed[63:0] ^ 64'hDEADBEEF_DEADBEEF);
        end
        check("Materica #1: phase violation detected", 1'b0);

        // ═══════════════════════════════════════════
        // Test 3: Materica #2 FAIL — Directional Violation
        // ═══════════════════════════════════════════
        $display("=== Test 3: Materica #2 - Directional Signal Violation ===");
        reset_all();
        repeat(5) @(posedge clk);
        ra_transaction_active = 1; ra_direction = 2'b01; // WRITE
        ra_source_id = 4'd1; ra_target_id = 4'd2;
        @(posedge clk);
        ra_target_id = 4'd3;  // different target — multi-target broadcast
        @(posedge clk);
        ra_transaction_active = 0;
        repeat(10) @(posedge clk);
        check("Materica #2: multi-target broadcast violation", 1'b0);

        // ═══════════════════════════════════════════
        // Test 4: Materica #3 FAIL — PIM Proximity (OOB)
        // ═══════════════════════════════════════════
        $display("=== Test 4: Materica #3 - PIM Proximity Violation ===");
        reset_all();
        // OOB address: row 0xFF >= CELL_ROWS → plane breach
        ra_transaction_active = 1; ra_direction = 2'b00;
        ra_addr = 32'hFF_FF_0000;
        @(posedge clk);
        @(posedge clk);
        ra_transaction_active = 0; ra_addr = 32'd0;
        repeat(5) @(posedge clk);
        check("Materica #3: OOB addressing -> dE>0 plane breach", 1'b0);

        // ═══════════════════════════════════════════
        // Test 5: Materica #4 FAIL — SBC Physical Attack
        // ═══════════════════════════════════════════
        $display("=== Test 5: Materica #4 - SBC Physical Attack ===");
        reset_all();
        phys_temp_alarm = 1;
        repeat(5) @(posedge clk);
        check("Materica #4: temperature alarm -> SBC fail", 1'b0);
        phys_temp_alarm = 0;

        // ═══════════════════════════════════════════
        // Test 6: SBC Irreversibility — Boundary Lost
        // ═══════════════════════════════════════════
        $display("=== Test 6: Materica #4 - SBC Boundary Irreversibility ===");
        reset_all();
        repeat(5) @(posedge clk);
        sec_boundary_intact = 0;   // break boundary
        repeat(5) @(posedge clk);
        sec_boundary_intact = 1;   // restore — should STILL be locked
        repeat(5) @(posedge clk);
        check("Materica #4: boundary breach irreversible - still FAIL after restore", 1'b0);

        // ═══════════════════════════════════════════
        // Summary
        // ═══════════════════════════════════════════
        $display("\n=== Materica Compliance Test Summary ===");
        $display("Total: %0d  Pass: %0d  Fail: %0d", test_total, test_pass, test_fail);
        if (test_fail == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d TESTS FAILED ***", test_fail);

        #20;
        if (test_fail != 0)
            $fatal;
        $finish;
    end

endmodule
