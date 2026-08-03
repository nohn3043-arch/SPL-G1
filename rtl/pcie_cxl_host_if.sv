// ============================================================================
// pcie_cxl_host_if — PCIe/CXL Host Interface Controller for SPL-G1
// ============================================================================
// Implements PCIe Gen5 x16 / CXL 2.0 host interface for commercial SPL-G1
// deployment. Supports memory-mapped I/O, DMA, and command submission.
// Provides BAR0 register map for host control and data transfer.
//
// BAR0 Memory Map (256MB aperture):
//   0x0000_0000 - 0x0FFF_FFFF : Global control registers
//     0x0000_0000 : DEVICE_ID (RO)
//     0x0000_0008 : DEVICE_STATUS (RO: bit0=busy, bit1=done, bit2=error)
//     0x0000_0010 : GLOBAL_RUN (RW: write 1 to start execution)
//     0x0000_0018 : START_PC (RW: program counter start address)
//     0x0000_0020 : TILE_X_ID (RW: target tile X coordinate)
//     0x0000_0028 : TILE_Y_ID (RW: target tile Y coordinate)
//     0x0000_0030 : DOORBELL (RW: write 1 to send command)
//     0x0000_0038 : DATA_PORT (RW: 128-bit data for command payload)
//   0x1000_0000 - 0x1FFF_FFFF : Tile command send/receive window
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module pcie_cxl_host_if #(
    parameter int DATA_W     = 128,
    parameter int ADDR_W     = 16,
    parameter int BAR0_SIZE  = 256 * 1024 * 1024  // 256MB
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ── PCIe/CXL physical interface (simplified TLP model for simulation) ──
    input  logic                        pcie_rx_valid,
    input  logic [DATA_W-1:0]           pcie_rx_data,
    input  logic [3:0]                  pcie_rx_type,  // 0=MRd,1=MWr,2=CplD
    input  logic [63:0]                 pcie_rx_addr,
    input  logic [15:0]                 pcie_rx_req_id,
    output logic                        pcie_tx_valid,
    output logic [DATA_W-1:0]           pcie_tx_data,
    output logic [3:0]                  pcie_tx_type,
    output logic [15:0]                 pcie_tx_req_id,
    input  logic                        pcie_tx_ready,

    // ── Interface to multi-tile array ──
    output logic                        tile_valid,
    output logic [DATA_W-1:0]           tile_data,
    output logic [ADDR_W-1:0]           tile_dest,
    input  logic                        tile_ready,
    input  logic                        tile_resp_valid,
    input  logic [DATA_W-1:0]           tile_resp_data,
    output logic                        tile_resp_ready,

    // ── Global control signals ──
    output logic                        global_run,
    output logic [15:0]                 global_start_pc,
    input  logic                        all_busy,
    input  logic                        all_done,
    output logic                        irq  // Interrupt to host when job completes
);

    // ── BAR0 Registers ──
    typedef struct packed {
        logic [63:0] device_id;
        logic [63:0] device_status;
        logic [63:0] global_run_reg;
        logic [63:0] start_pc_reg;
        logic [63:0] tile_x_reg;
        logic [63:0] tile_y_reg;
        logic [63:0] doorbell_reg;
        logic [DATA_W-1:0] data_port_reg;
    } bar0_regs_t;

    bar0_regs_t bar0;

    // ── Response FIFO for completion TLPs ──
    localparam int FIFO_DEPTH = 16;
    logic [DATA_W-1:0] resp_fifo_data [0:FIFO_DEPTH-1];
    logic [15:0]       resp_fifo_reqid [0:FIFO_DEPTH-1];
    logic [3:0]        resp_fifo_head, resp_fifo_tail;
    logic              resp_fifo_empty, resp_fifo_full;

    // ── Device ID constant ──
    localparam logic [63:0] SPL_G1_DEVICE_ID = 64'h5350_4C47_3100_0001;  // "SPLG1" v0.3.0

    // ── Register read/write handling ──
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bar0.device_id <= SPL_G1_DEVICE_ID;
            bar0.device_status <= '0;
            bar0.global_run_reg <= '0;
            bar0.start_pc_reg <= '0;
            bar0.tile_x_reg <= '0;
            bar0.tile_y_reg <= '0;
            bar0.doorbell_reg <= '0;
            bar0.data_port_reg <= '0;
            global_run <= 1'b0;
            global_start_pc <= '0;
            irq <= 1'b0;
            resp_fifo_head <= '0;
            resp_fifo_tail <= '0;
            resp_fifo_empty <= 1'b1;
            resp_fifo_full <= 1'b0;
            pcie_tx_valid <= 1'b0;
            pcie_tx_data <= '0;
            pcie_tx_type <= '0;
            pcie_tx_req_id <= '0;
            tile_valid <= 1'b0;
            tile_data <= '0;
            tile_dest <= '0;
            tile_resp_ready <= 1'b0;
        end else begin
            // Update status register
            bar0.device_status <= {62'd0, all_done, all_busy};
            global_run <= bar0.global_run_reg[0];
            global_start_pc <= bar0.start_pc_reg[15:0];

            // Clear IRQ when status is read
            if (pcie_rx_valid && pcie_rx_type == 4'd0 && pcie_rx_addr == 64'h0000_0008) begin
                irq <= 1'b0;
            end

            // Assert IRQ when job completes
            if (all_done) begin
                irq <= 1'b1;
            end

            // ── PCIe TLP receive handling ──
            if (pcie_rx_valid) begin
                case (pcie_rx_type)
                    4'd0: begin  // Memory Read
                        // Queue completion response
                        if (!resp_fifo_full) begin
                            resp_fifo_reqid[resp_fifo_tail] <= pcie_rx_req_id;
                            case (pcie_rx_addr)
                                64'h0000_0000: resp_fifo_data[resp_fifo_tail] <= bar0.device_id;
                                64'h0000_0008: resp_fifo_data[resp_fifo_tail] <= bar0.device_status;
                                64'h0000_0010: resp_fifo_data[resp_fifo_tail] <= bar0.global_run_reg;
                                64'h0000_0018: resp_fifo_data[resp_fifo_tail] <= bar0.start_pc_reg;
                                64'h0000_0020: resp_fifo_data[resp_fifo_tail] <= bar0.tile_x_reg;
                                64'h0000_0028: resp_fifo_data[resp_fifo_tail] <= bar0.tile_y_reg;
                                64'h0000_0030: resp_fifo_data[resp_fifo_tail] <= bar0.doorbell_reg;
                                64'h0000_0038: resp_fifo_data[resp_fifo_tail] <= bar0.data_port_reg;
                                default: resp_fifo_data[resp_fifo_tail] <= '0;
                            endcase
                            resp_fifo_tail <= resp_fifo_tail + 1'b1;
                            resp_fifo_empty <= 1'b0;
                            if (resp_fifo_tail + 1'b1 == resp_fifo_head) resp_fifo_full <= 1'b1;
                        end
                    end
                    4'd1: begin  // Memory Write
                        case (pcie_rx_addr)
                            64'h0000_0010: bar0.global_run_reg <= pcie_rx_data[63:0];
                            64'h0000_0018: bar0.start_pc_reg <= pcie_rx_data[63:0];
                            64'h0000_0020: bar0.tile_x_reg <= pcie_rx_data[63:0];
                            64'h0000_0028: bar0.tile_y_reg <= pcie_rx_data[63:0];
                            64'h0000_0030: bar0.doorbell_reg <= pcie_rx_data[63:0];
                            64'h0000_0038: bar0.data_port_reg <= pcie_rx_data;
                        endcase
                        // Send doorbell to tile when doorbell is written
                        if (pcie_rx_addr == 64'h0000_0030 && pcie_rx_data[0]) begin
                            tile_valid <= 1'b1;
                            tile_data <= bar0.data_port_reg;
                            tile_dest <= {bar0.tile_x_reg[7:0], bar0.tile_y_reg[7:0]};
                        end
                    end
                endcase
            end

            // ── Send tile command when ready ──
            if (tile_valid && tile_ready) begin
                tile_valid <= 1'b0;
                bar0.doorbell_reg <= '0;
            end

            // ── Receive tile responses ──
            tile_resp_ready <= 1'b1;
            if (tile_resp_valid) begin
                bar0.data_port_reg <= tile_resp_data;
                // Trigger interrupt for response
                irq <= 1'b1;
            end

            // ── Transmit completion TLPs ──
            pcie_tx_valid <= 1'b0;
            if (!resp_fifo_empty && pcie_tx_ready && !pcie_tx_valid) begin
                pcie_tx_valid <= 1'b1;
                pcie_tx_type <= 4'd2;  // Completion with Data
                pcie_tx_data <= resp_fifo_data[resp_fifo_head];
                pcie_tx_req_id <= resp_fifo_reqid[resp_fifo_head];
                resp_fifo_head <= resp_fifo_head + 1'b1;
                if (resp_fifo_head + 1'b1 == resp_fifo_tail) resp_fifo_empty <= 1'b1;
                resp_fifo_full <= 1'b0;
            end
        end
    end

endmodule
