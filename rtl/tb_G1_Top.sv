`timescale 1ns / 1ps
// SPL-G1 Top-Level Testbench  (v0.2.0 — meaningful causal audit tests)
//
// Tests:
//   Case 1 — Identity anchor: 64-cycle hash verification  →  expects PASS
//   Case 2 — Valid P→Q:  clean STATE compute                →  expects STABLE
//   Case 3 — Forbidden P→Q:  DE→AD transition               →  expects NOT STABLE
//   Case 4 — IAP violation:   privilege bypass (P=0xFF)     →  expects NOT STABLE

module tb_G1_Top_Interface;

    // ── DUT signals ────────────────────────────────────────────────
    logic         clk;
    logic         rst_n;
    logic [511:0] internal_logic_stream;
    logic [255:0] hardware_hash_in;
    logic         ra_bus_valid;
    logic [31:0]  ra_bus_addr;
    wire          pim_state_stable;
    wire          logic_integrity_verified;

    // ── Test tracking ──────────────────────────────────────────────
    integer       test_pass, test_fail;
    localparam [255:0] G1_ID = 256'h8525D007_59A4_CA22_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000;

    // ── DUT instantiation ──────────────────────────────────────────
    G1_Top_Interface uut (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .internal_logic_stream  (internal_logic_stream),
        .hardware_hash_in       (hardware_hash_in),
        .ra_bus_valid           (ra_bus_valid),
        .ra_bus_addr            (ra_bus_addr),
        .pim_state_stable       (pim_state_stable),
        .logic_integrity_verified(logic_integrity_verified)
    );

    // ── Clock (1 GHz) ──────────────────────────────────────────────
    initial begin
        clk = 0;
        forever #0.5 clk = ~clk;
    end

    // ── VCD dump ───────────────────────────────────────────────────
    initial begin
        $dumpfile("g1_core_wave.vcd");
        $dumpvars(0, tb_G1_Top_Interface);
    end

    // ================================================================
    //  TASKS
    // ================================================================

    // ── Hardware identity verification (64-cycle nibble handshake) ─
    task automatic verify_identity;
        begin
            ra_bus_valid = 1;
            ra_bus_addr  = 32'h8;                          // bit[3]=1 → hash strobe
            for (integer n = 0; n < 64; n++) begin
                hardware_hash_in = {252'd0, G1_ID[n*4 +: 4]};
                @(posedge clk);
            end
            ra_bus_valid = 0;
            ra_bus_addr  = 32'd0;
            // Wait for verification to complete
            repeat (5) @(posedge clk);
        end
    endtask

    // ── Start a compute operation via RA-BUS ───────────────────────
    task automatic start_compute(
        input [2:0]  op_mode,
        input [63:0] op_a,
        input [63:0] op_b
    );
        begin
            // Format: internal_logic_stream = {reserved[511:320], op_mode[319:317], op_a[255:128], op_b[127:0]}
            internal_logic_stream[319:317] = op_mode;
            internal_logic_stream[255:128] = op_a;
            internal_logic_stream[127:0]   = op_b;
            ra_bus_valid = 1;
            ra_bus_addr  = 32'h4;                          // bit[2]=1 → compute start
            @(posedge clk);
            ra_bus_valid = 0;
            ra_bus_addr  = 32'd0;
            repeat (2) @(posedge clk);
        end
    endtask

    // ── Wait until pim_state_stable or timeout ────────────────────
    task automatic wait_stable(output logic stable);
        integer timeout;
        begin
            stable = 0;
            timeout = 0;
            while (!pim_state_stable && timeout < 200) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            stable = pim_state_stable;
        end
    endtask

    // ── Report test result ─────────────────────────────────────────
    task automatic check(
        input string   name,
        input logic    actual,
        input logic    expected
    );
        begin
            if (actual == expected) begin
                $display("[PASS] %s", name);
                test_pass = test_pass + 1;
            end else begin
                $display("[FAIL] %s  (expected %b, got %b)", name, expected, actual);
                test_fail = test_fail + 1;
            end
        end
    endtask

    // ================================================================
    //  MAIN TEST SEQUENCE
    // ================================================================
    initial begin
        test_pass = 0;
        test_fail = 0;

        // ── Reset ──────────────────────────────────────────────────
        $display("\n===== SPL-G1 Hardware Audit Test Suite =====\n");
        rst_n            = 0;
        ra_bus_valid     = 0;
        ra_bus_addr      = 32'd0;
        hardware_hash_in = 256'd0;
        internal_logic_stream = 512'd0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset released at %t", $time);

        // ============================================================
        //  TEST 1: Identity anchor verification
        // ============================================================
        $display("\n--- Test 1: Identity Anchor Verification ---");
        verify_identity();
        check("Hardware identity verified", logic_integrity_verified, 1'b1);

        // ============================================================
        //  TEST 2: Valid causal computation (STATE mode)
        // ============================================================
        $display("\n--- Test 2: Valid Causal Computation ---");
        // op_a=42, op_b=58 → result=100. Clean P→Q, all bits pass NS/IAP/AUDIT.
        start_compute(/*STATE*/ 3'd4, 64'd42, 64'd58);
        begin
            logic stable;
            wait_stable(stable);
            check("Valid P→Q causal audit passes", stable, 1'b1);
        end

        // ============================================================
        //  TEST 3: Forbidden P→Q transition  (DE→AD)
        // ============================================================
        $display("\n--- Test 3: Forbidden Transition (DE→AD) ---");
        // P[7:0] = op_b[7:0] = 0xDE,  Q[7:0] = (0xCF + 0xDE)[7:0] = 0xAD
        // Forbidden matrix entry #2 catches this.
        start_compute(/*STATE*/ 3'd4, 64'hCF, 64'hDE);
        begin
            logic stable;
            wait_stable(stable);
            check("Forbidden DE→AD rejected", stable, 1'b0);
        end

        // ============================================================
        //  TEST 4: IAP violation — privilege bypass pattern
        // ============================================================
        $display("\n--- Test 4: IAP Privilege Bypass (P=0xFF) ---");
        // P[7:0] = op_b[7:0] = 0xFF  →  iap_flags[1] fires
        start_compute(/*STATE*/ 3'd4, 64'd1, 64'hFF);
        begin
            logic stable;
            wait_stable(stable);
            check("IAP privilege bypass rejected", stable, 1'b0);
        end

        // ============================================================
        //  SUMMARY
        // ============================================================
        $display("\n===== Results: %0d passed, %0d failed =====\n", test_pass, test_fail);

        if (test_fail == 0)
            $display("[FINAL] ALL TESTS PASSED. Causal audit pipeline functional.");
        else
            $display("[FINAL] %0d TEST(S) FAILED. Review above.", test_fail);

        #20;
        $finish;
    end

endmodule
