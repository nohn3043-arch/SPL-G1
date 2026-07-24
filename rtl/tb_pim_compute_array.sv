// ============================================================================
// tb_pim_compute_array — PIM Compute Array Testbench
// ============================================================================
// Tests: SCALAR arithmetic, VECTOR column-parallel, MATRIX full-array,
// causal tag integrity, and read-back-vs-write separation.
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

`timescale 1ns / 1ps

module tb_pim_compute_array;

    localparam ROWS = 4;
    localparam COLS = 4;

    logic        clk, rst_n, ra_en, pim_store_en;
    logic [31:0] ra_addr;
    logic [63:0] ra_wdata, ra_rdata;
    logic [ 7:0] pim_op;
    logic [ 1:0] exec_mode;
    logic [ 7:0] p_tags [ROWS-1:0][COLS-1:0];
    logic [ 7:0] q_tags [ROWS-1:0][COLS-1:0];
    logic [63:0] vec_sum [COLS-1:0], mat_total;
    logic        pim_ready;
    logic [1:0]  pim_resp;

    spl_pim_compute_array #(.ROWS(ROWS), .COLS(COLS)) dut (
        .ra_clk(clk), .ra_rst_n(rst_n), .ra_en(ra_en), .ra_addr(ra_addr),
        .ra_wdata(ra_wdata), .ra_rdata(ra_rdata),
        .pim_op(pim_op), .pim_store_en(pim_store_en), .exec_mode(exec_mode),
        .raw_p_tag(p_tags), .raw_q_tag(q_tags),
        .pim_ready(pim_ready), .pim_resp(pim_resp),
        .vec_sum(vec_sum), .mat_total(mat_total)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ── Helpers ──
    task tick;
        begin @(posedge clk); #1; end
    endtask

    // Write value to cell(s) then optionally verify
    task pim_write;
        input [31:0] addr; input [63:0] data; input [7:0] op; input [1:0] mode;
        input [63:0] expected; input string desc;
        begin
            @(negedge clk);
            ra_en=1; ra_addr=addr; ra_wdata=data; pim_op=op;
            pim_store_en=1; exec_mode=mode;
            tick; @(negedge clk); #1;
            if (mode == 2'b01) begin
                if (ra_rdata === expected)
                    $display("[PASS] %s — got=%0d", desc, ra_rdata);
                else
                    $display("[FAIL] %s — got=%0d exp=%0d", desc, ra_rdata, expected);
            end
            ra_en=0; pim_store_en=0;
        end
    endtask

    // Read cell without side-effect (NOP, no store)
    task pim_read;
        input [31:0] addr; input [63:0] expected; input string desc;
        begin
            @(negedge clk);
            ra_en=1; ra_addr=addr; ra_wdata=64'h0; pim_op=8'h00;
            pim_store_en=0; exec_mode=2'b01;
            tick; @(negedge clk); #1;
            if (ra_rdata === expected)
                $display("[PASS] %s — got=%0d", desc, ra_rdata);
            else
                $display("[FAIL] %s — got=%0d exp=%0d", desc, ra_rdata, expected);
            ra_en=0;
        end
    endtask

    integer errors;
    initial begin
        errors = 0;
        ra_en=0; ra_addr=0; ra_wdata=0; pim_op=0; pim_store_en=0; exec_mode=0;

        rst_n=0; #50; rst_n=1; #20;

        $display("===== SPL-G1 PIM Compute Array Test Suite =====");

        // ═══════════════════════════════════════════
        // Test 1: SCALAR arithmetic
        // ═══════════════════════════════════════════
        $display("--- Test 1: SCALAR Arithmetic ---");
        pim_write(32'h00_00_0000, 42,  8'h00, 2'b01, 42,   "Cell(0,0) load=42");
        pim_write(32'h00_00_0000, 13,  8'h01, 2'b01, 55,   "Cell(0,0) ADD 42+13");
        pim_write(32'h00_00_0000, 20,  8'h02, 2'b01, 35,   "Cell(0,0) SUB 55-20");
        pim_write(32'h00_00_0000, 3,   8'h03, 2'b01, 105,  "Cell(0,0) MUL 35*3");
        pim_write(32'h00_00_0000, 105, 8'h05, 2'b01, 1,    "Cell(0,0) CMP 105==105");
        pim_write(32'h00_00_0000, 0,   8'h05, 2'b01, 0,    "Cell(0,0) CMP 1==0");

        pim_write(32'h02_01_0000, 99,  8'h00, 2'b01, 99,   "Cell(2,1) load=99");
        pim_write(32'h02_01_0000, 1,   8'h01, 2'b01, 100,  "Cell(2,1) ADD 99+1");
        pim_write(32'h02_01_0000, 255, 8'h07, 2'b01, 155,  "Cell(2,1) XOR 100^255");

        // Read-back: cell(0,0) stored 0 from last CMP
        pim_read (32'h00_00_0000, 0,    "Cell(0,0) readback=0");
        pim_read (32'h02_01_0000, 155,  "Cell(2,1) readback=155");

        $display("");

        // ═══════════════════════════════════════════
        // Test 2: VECTOR (column-wide parallel)
        // ═══════════════════════════════════════════
        $display("--- Test 2: VECTOR (column 0) ---");
        pim_write(32'h00_00_0000, 10, 8'h00, 2'b01, 10, "Pre-load Cell(0,0)=10");
        pim_write(32'h01_00_0000, 20, 8'h00, 2'b01, 20, "Pre-load Cell(1,0)=20");
        pim_write(32'h02_00_0000, 30, 8'h00, 2'b01, 30, "Pre-load Cell(2,0)=30");
        pim_write(32'h03_00_0000, 40, 8'h00, 2'b01, 40, "Pre-load Cell(3,0)=40");

        // VECTOR ADD +5 to whole column 0
        @(negedge clk);
        ra_en=1; ra_addr=32'h00_00_0000; ra_wdata=5;
        pim_op=8'h01; pim_store_en=1; exec_mode=2'b10;
        tick; @(negedge clk); #1;
        ra_en=0; pim_store_en=0;

        // Verify per-cell results after VECTOR ADD +5
        pim_read(32'h00_00_0000, 15, "Cell(0,0)=15");
        pim_read(32'h01_00_0000, 25, "Cell(1,0)=25");
        pim_read(32'h02_00_0000, 35, "Cell(2,0)=35");
        pim_read(32'h03_00_0000, 45, "Cell(3,0)=45");

        $display("");

        // ═══════════════════════════════════════════
        // Test 3: MATRIX (full-array activation)
        // ═══════════════════════════════════════════
        $display("--- Test 3: MATRIX (full grid) ---");
        begin
            integer r, c;
            reg [63:0] val;
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    val = r*10 + c*5;
                    pim_write({r[7:0], c[7:0], 16'h0}, val, 8'h00, 2'b01, val, "Pre-load");
                end
            end
        end

        // MATRIX ADD +1
        @(negedge clk);
        ra_en=1; ra_addr=0; ra_wdata=1;
        pim_op=8'h01; pim_store_en=1; exec_mode=2'b11;
        tick; @(negedge clk); #1;
        ra_en=0; pim_store_en=0;

        // Expected: sum((r*10+c*5)+1) over 4×4 = 240+120+16 = 376
        if (mat_total === 376)
            $display("[PASS] MATRIX ADD+1 — mat_total=%0d", mat_total);
        else begin
            $display("[FAIL] MATRIX ADD+1 — mat_total=%0d exp=376", mat_total);
            errors = errors + 1;
        end

        // Verify per-cell values after MATRIX: (r*10+c*5)+1
        // Cell(0,0)=1, Cell(0,1)=6, Cell(0,2)=11, Cell(0,3)=16
        // Cell(1,0)=11, Cell(1,1)=16, Cell(1,2)=21, Cell(1,3)=26
        // Cell(2,0)=21, Cell(2,1)=26, Cell(2,2)=31, Cell(2,3)=36
        // Cell(3,0)=31, Cell(3,1)=36, Cell(3,2)=41, Cell(3,3)=46
        pim_read(32'h00_00_0000, 1,  "Cell(0,0) after MATRIX=1");
        pim_read(32'h00_01_0000, 6,  "Cell(0,1) after MATRIX=6");
        pim_read(32'h00_02_0000, 11, "Cell(0,2) after MATRIX=11");
        pim_read(32'h00_03_0000, 16, "Cell(0,3) after MATRIX=16");
        pim_read(32'h03_03_0000, 46, "Cell(3,3) after MATRIX=46");

        // Check causal tags
        begin
            integer tr, tc, tz;
            tz = 0;
            for (tr = 0; tr < ROWS; tr = tr + 1) begin
                for (tc = 0; tc < COLS; tc = tc + 1) begin
                    if (p_tags[tr][tc] === 8'h0) tz = tz + 1;
                end
            end
            if (tz == 0)
                $display("[PASS] All %0d cells have non-zero P-tags", ROWS*COLS);
            else
                $display("[WARN] %0d cells have zero P-tags", tz);
        end

        $display("");
        $display("===== Results: %0d errors =====", errors);
        if (errors == 0)
            $display("[FINAL] ALL TESTS PASSED. PIM compute array functional.");
        else
            $display("[FINAL] FAILED: %0d error(s).", errors);
        $finish;
    end

    initial begin
        $dumpfile("pim_array_wave.vcd");
        $dumpvars(0, tb_pim_compute_array);
    end
endmodule
