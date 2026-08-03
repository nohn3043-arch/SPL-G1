// ============================================================================
// materica_compliance_unit_v2 — 硬件级 Materica 四项因果映射合规单元
// ============================================================================
// Materica #1: Binary Phase Constraint → dsigma_monitor (packed cell states)
// Materica #2: Directional Signal       → ra_direction_guard
// Materica #3: PIM Proximity ΔE≈0       → pim_proximity_monitor (OOB = plane breach)
// Materica #4: SBC Irreversibility      → physical_fuse_controller
//
// v2 changes:
//   - All cell-array ports are PACKED vectors (iverilog-compatible across
//     module boundaries; unpacked 2D arrays crash iverilog elaborate).
//   - #3 detection: out-of-bounds addressing = addressing non-existent
//     storage = breaking the PIM plane (ΔE>0 implies transport to
//     somewhere outside the compute plane).
//
// 合规判定：四项全部 PASS → materica_compliant = 1
// 任一 FAIL → fuse_trigger = 1（物理熔断路径，与逻辑 audit 熔断并行）
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module materica_compliance_unit #(
    parameter int CELL_ROWS     = 4,
    parameter int CELL_COLS     = 4,
    parameter int CELL_DATA_W   = 64,    // v3: per-cell data width (64=legacy, 128=expanded)
    parameter int PHASE_WINDOW  = 16,     // Materica #1: 状态保持监测窗口（周期）
    parameter int DIR_VIOLATION_THRESH = 3 // Materica #2: 方向违规阈值
) (
    input  logic         clk,
    input  logic         rst_n,

    // ─── Materica #1: Binary Phase Constraint ───
    // PACKED cell state/op vectors: [CELL_ROWS*CELL_COLS*W-1:0]
    // Bit layout: cell (r,c) occupies [((r*COLS+c)+1)*W-1 : (r*COLS+c)*W]
    input  logic [CELL_ROWS*CELL_COLS*CELL_DATA_W-1:0] cell_states_packed,
    input  logic [CELL_ROWS*CELL_COLS*5 -1:0] cell_ops_packed,

    // ─── Materica #2: Directional Signal ───
    input  logic         ra_transaction_active,
    input  logic [ 3:0]  ra_source_id,
    input  logic [ 3:0]  ra_target_id,
    input  logic [ 1:0]  ra_direction,    // 00:READ 01:WRITE 10:EXEC 11:CONFIG

    // ─── Materica #3: PIM Proximity ΔE_transport ≈ 0 ───
    // OOB detection: addressed row/col must exist inside the plane.
    input  logic [31:0]  ra_addr,         // [31:24]=row, [23:16]=col

    // ─── Materica #4: SBC Irreversibility ───
    input  logic         phys_temp_alarm,
    input  logic         phys_volt_alarm,
    input  logic         phys_rad_alarm,
    input  logic         sec_boundary_intact,

    // ─── 合规输出 ───
    output logic         materica_compliant,
    output logic [ 3:0]  compliance_status,   // [3]=SBC [2]=PIM [1]=DIR [0]=PHASE
    output logic         fuse_trigger
);

    // ═══════════════════════════════════════════════
    // Packed → unpacked unpack (generate, constant indices only)
    // ═══════════════════════════════════════════════
    logic [CELL_DATA_W-1:0] cell_state [CELL_ROWS-1:0][CELL_COLS-1:0];
    logic [ 4:0] cell_op    [CELL_ROWS-1:0][CELL_COLS-1:0];

    genvar ur, uc;
    generate
        for (ur = 0; ur < CELL_ROWS; ur = ur + 1) begin : gen_unpack_r
            for (uc = 0; uc < CELL_COLS; uc = uc + 1) begin : gen_unpack_c
                assign cell_state[ur][uc] = cell_states_packed[((ur*CELL_COLS+uc)+1)*CELL_DATA_W-1 -: CELL_DATA_W];
                assign cell_op[ur][uc]    = cell_ops_packed[((ur*CELL_COLS+uc)+1)*5 -1 -: 5];
            end
        end
    endgenerate

    // ═══════════════════════════════════════════════
    // Materica #1: Binary Phase Constraint Monitor
    // ═══════════════════════════════════════════════
    // 要求：σ₀ → σ₁ 转换必须无中间态；NOP 下无自发翻转。
    // 实现：每 cell 滑动窗口，NOP 但状态变化 → 稳定性计数右移（衰减）。
    logic        phase_violation;
    logic [PHASE_WINDOW-1:0] phase_counter [CELL_ROWS-1:0][CELL_COLS-1:0];
    logic [CELL_DATA_W-1:0] prev_state  [CELL_ROWS-1:0][CELL_COLS-1:0];

    integer pi, pj;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_violation <= 1'b0;
            for (pi = 0; pi < CELL_ROWS; pi = pi + 1)
                for (pj = 0; pj < CELL_COLS; pj = pj + 1) begin
                    prev_state[pi][pj] <= {CELL_DATA_W{1'b0}};
                    phase_counter[pi][pj] <= {PHASE_WINDOW{1'b1}};
                end
        end else begin
            phase_violation <= 1'b0;
            for (pi = 0; pi < CELL_ROWS; pi = pi + 1)
                for (pj = 0; pj < CELL_COLS; pj = pj + 1) begin
                    // NOP (op==0) 但状态变了 → 自发翻转 → 计数衰减
                    if (cell_op[pi][pj] == 5'h00 &&
                        cell_state[pi][pj] != prev_state[pi][pj]) begin
                        phase_counter[pi][pj] <= phase_counter[pi][pj] >> 1;
                    end else begin
                        phase_counter[pi][pj] <= {phase_counter[pi][pj][PHASE_WINDOW-2:0], 1'b1};
                    end
                    prev_state[pi][pj] <= cell_state[pi][pj];
                    // 任一 cell 计数跌破 1/8 满值 → violation
                    if (phase_counter[pi][pj] < ({PHASE_WINDOW{1'b1}} >> 3))
                        phase_violation <= 1'b1;
                end
        end
    end

    wire phase_pass = !phase_violation;

    // ═══════════════════════════════════════════════
    // Materica #2: Directional Signal Guard
    // ═══════════════════════════════════════════════
    // 禁止各向同性扩散：同一事务多目标 WRITE = 数字等价广播 → 粘性锁存。
    // CONFIG(source≠target) 反向事务计数。
    logic        direction_violation;
    logic [ 2:0] dir_violation_count;
    logic [ 3:0] prev_target_id;
    logic        multi_target_latched;   // 粘性：一旦置位仅复位清除

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            direction_violation <= 1'b0;
            dir_violation_count <= 3'd0;
            prev_target_id <= 4'd0;
            multi_target_latched <= 1'b0;
        end else begin
            if (ra_transaction_active && ra_direction == 2'b01) begin // WRITE
                if (prev_target_id != 4'd0 && ra_target_id != prev_target_id)
                    multi_target_latched <= 1'b1;
                prev_target_id <= ra_target_id;
            end

            if (ra_transaction_active && ra_direction == 2'b11 && ra_source_id != ra_target_id)
                dir_violation_count <= dir_violation_count + 1;
            else if (dir_violation_count > 0)
                dir_violation_count <= dir_violation_count - 1;

            direction_violation <= (dir_violation_count >= DIR_VIOLATION_THRESH) || multi_target_latched;
        end
    end

    wire direction_pass = !direction_violation;

    // ═══════════════════════════════════════════════
    // Materica #3: PIM Proximity Monitor — OOB = plane breach
    // ═══════════════════════════════════════════════
    // 存算一体平面：寻址范围 [0, ROWS-1]×[0, COLS-1]。
    // 越界寻址 = 指向平面之外的存储 = 必须发生跨平面数据搬运（ΔE>0）。
    // 粘性锁存：OOB 一旦发生 → 永久记录。
    logic        pim_proximity_violation;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pim_proximity_violation <= 1'b0;
        end else if (ra_transaction_active &&
                     (ra_addr[31:24] >= CELL_ROWS || ra_addr[23:16] >= CELL_COLS)) begin
            pim_proximity_violation <= 1'b1;
        end
    end

    wire pim_proximity_pass = !pim_proximity_violation;

    // ═══════════════════════════════════════════════
    // Materica #4: SBC Irreversibility Controller
    // ═══════════════════════════════════════════════
    // 物理破坏 → 永久锁定。边界完整性丢失 → 锁存不可逆。
    logic sec_bnd_lost_latch;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sec_bnd_lost_latch <= 1'b0;
        end else if (!sec_boundary_intact) begin
            sec_bnd_lost_latch <= 1'b1;
        end
    end

    wire sbc_physical_attack = phys_temp_alarm || phys_volt_alarm || phys_rad_alarm;
    wire sbc_pass = !sbc_physical_attack && !sec_bnd_lost_latch && sec_boundary_intact;

    // ═══════════════════════════════════════════════
    // 合规判定 & 熔断触发
    // ═══════════════════════════════════════════════
    assign compliance_status = {sbc_pass, pim_proximity_pass, direction_pass, phase_pass};
    assign materica_compliant = &compliance_status;
    assign fuse_trigger = !materica_compliant;

    // ─── 仿真辅助：合规状态报告 ───
    `ifdef SIMULATION
    always @(posedge clk) begin
        if (!materica_compliant && |compliance_status) begin
            if (!phase_pass)         $display("[MATERICA] #1 FAIL: Binary Phase Constraint violated");
            if (!direction_pass)     $display("[MATERICA] #2 FAIL: Directional Signal violated");
            if (!pim_proximity_pass) $display("[MATERICA] #3 FAIL: PIM Proximity ΔE>0 detected (OOB)");
            if (!sbc_pass)           $display("[MATERICA] #4 FAIL: SBC physical boundary breached");
        end
    end
    `endif

endmodule
