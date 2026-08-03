// ============================================================================
// spl_pim_reduce_tree — Pipelined Binary Reduction Tree (O(logN) latency)
// ============================================================================
// Replaces the combinational reduction in spl_pim_compute_array for large
// arrays (16x16=256 inputs). Fully parameterized, supports any power-of-two
// input count. Pipeline registers inserted at every level for timing closure.
//
// Latency: $clog2(NUM_INPUTS) cycles
// Throughput: 1 result per cycle (fully pipelined)
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module spl_pim_reduce_tree #(
    parameter int NUM_INPUTS = 256,  // Must be power of two
    parameter int DATA_W     = 128
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        in_valid,
    input  logic [DATA_W-1:0]           in_data [NUM_INPUTS-1:0],
    output logic                        out_valid,
    output logic [DATA_W-1:0]           out_data
);

    // Calculate number of pipeline stages
    localparam int LEVELS = $clog2(NUM_INPUTS);

    // Pipeline registers: level 0 = input, level LEVELS = output
    logic [DATA_W-1:0] pipe [0:LEVELS][NUM_INPUTS-1:0];
    logic              pipe_valid [0:LEVELS];

    // Input stage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_valid[0] <= 1'b0;
            for (int i = 0; i < NUM_INPUTS; i++)
                pipe[0][i] <= '0;
        end else begin
            pipe_valid[0] <= in_valid;
            for (int i = 0; i < NUM_INPUTS; i++)
                pipe[0][i] <= in_data[i];
        end
    end

    // Generate pipeline levels
    generate
        for (genvar lvl = 0; lvl < LEVELS; lvl = lvl + 1) begin : gen_level
            localparam int ELEMS = NUM_INPUTS >> (lvl + 1);
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pipe_valid[lvl+1] <= 1'b0;
                    for (int i = 0; i < ELEMS; i++)
                        pipe[lvl+1][i] <= '0;
                end else begin
                    pipe_valid[lvl+1] <= pipe_valid[lvl];
                    for (int i = 0; i < ELEMS; i++) begin
                        // Saturating addition for reduction
                        pipe[lvl+1][i] <= pipe[lvl][2*i] + pipe[lvl][2*i+1];
                    end
                end
            end
        end
    endgenerate

    // Output
    assign out_valid = pipe_valid[LEVELS];
    assign out_data  = pipe[LEVELS][0];

endmodule
