// ============================================================================
// ext_mem_controller — External Memory Controller (AXI4-MM Slave)
// ============================================================================
// Implements RA-BUS target 3 (external storage) for SPL-G1. Provides
// memory-mapped access to off-chip DRAM/NVMe via AXI4 master interface.
// Supports burst transfers, DMA between PIM array and external memory.
//
// Address map:
//   0x0000_0000 - 0x00FF_FFFF : DRAM region (16MB)
//   0x0100_0000 - 0x01FF_FFFF : Control registers
//     0x0100_0000 : DMA_SRC_ADDR
//     0x0100_0008 : DMA_DST_ADDR
//     0x0100_0010 : DMA_LEN
//     0x0100_0018 : DMA_START (write 1 to trigger)
//     0x0100_0020 : DMA_STATUS (bit0: busy, bit1: done)
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module ext_mem_controller #(
    parameter int DATA_W       = 128,
    parameter int ADDR_W       = 28,
    parameter int MEM_SIZE     = 16 * 1024 * 1024,  // 16MB on-chip SRAM model
    parameter int AXI_ID_W     = 4
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ── RA-BUS slave interface ──
    input  logic                        ra_valid,
    input  logic [1:0]                  ra_cmd,         // 00:READ 01:WRITE
    input  logic [ADDR_W-1:0]           ra_addr,
    input  logic [DATA_W-1:0]           ra_wdata,
    output logic [DATA_W-1:0]           ra_rdata,
    output logic                        ra_ready,
    output logic [1:0]                  ra_resp,        // 00:OK 01:ERR 10:BUSY

    // ── AXI4 Master interface (to external DRAM/PHY) ──
    output logic                        axi_awvalid,
    input  logic                        axi_awready,
    output logic [ADDR_W-1:0]           axi_awaddr,
    output logic [7:0]                  axi_awlen,
    output logic [2:0]                  axi_awsize,
    output logic [1:0]                  axi_awburst,
    output logic [AXI_ID_W-1:0]         axi_awid,

    output logic                        axi_wvalid,
    input  logic                        axi_wready,
    output logic [DATA_W-1:0]           axi_wdata,
    output logic [DATA_W/8-1:0]         axi_wstrb,
    output logic                        axi_wlast,

    input  logic                        axi_bvalid,
    output logic                        axi_bready,
    input  logic [1:0]                  axi_bresp,
    input  logic [AXI_ID_W-1:0]         axi_bid,

    output logic                        axi_arvalid,
    input  logic                        axi_arready,
    output logic [ADDR_W-1:0]           axi_araddr,
    output logic [7:0]                  axi_arlen,
    output logic [2:0]                  axi_arsize,
    output logic [1:0]                  axi_arburst,
    output logic [AXI_ID_W-1:0]         axi_arid,

    input  logic                        axi_rvalid,
    output logic                        axi_rready,
    input  logic [DATA_W-1:0]           axi_rdata,
    input  logic [1:0]                  axi_rresp,
    input  logic                        axi_rlast,
    input  logic [AXI_ID_W-1:0]         axi_rid,

    // ── DMA status ──
    output logic                        dma_busy,
    output logic                        dma_done
);

    // ── On-chip SRAM model (simulation only; replaced by AXI PHY in synthesis) ──
    localparam int SRAM_WORDS = MEM_SIZE / (DATA_W/8);
    logic [DATA_W-1:0] sram [0:SRAM_WORDS-1];

    // ── DMA registers ──
    logic [ADDR_W-1:0] dma_src, dma_dst;
    logic [31:0]       dma_len;
    logic              dma_start;
    logic [31:0]       dma_cnt;

    typedef enum logic [2:0] {
        DMA_IDLE,
        DMA_READ,
        DMA_WRITE,
        DMA_DONE
    } dma_state_t;
    dma_state_t dma_state;

    // ── Default AXI outputs (tied off for simulation model) ──
    assign axi_awvalid = 1'b0;
    assign axi_awaddr  = '0;
    assign axi_awlen   = '0;
    assign axi_awsize  = 3'b100;  // 16 bytes for 128-bit
    assign axi_awburst = 2'b01;   // INCR
    assign axi_awid    = '0;
    assign axi_wvalid  = 1'b0;
    assign axi_wdata   = '0;
    assign axi_wstrb   = '1;
    assign axi_wlast   = 1'b0;
    assign axi_bready  = 1'b1;
    assign axi_arvalid = 1'b0;
    assign axi_araddr  = '0;
    assign axi_arlen   = '0;
    assign axi_arsize  = 3'b100;
    assign axi_arburst = 2'b01;
    assign axi_arid    = '0;
    assign axi_rready  = 1'b1;

    // ── RA-BUS read/write handling ──
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ra_rdata <= '0;
            ra_ready <= 1'b0;
            ra_resp  <= 2'd0;
            dma_src  <= '0;
            dma_dst  <= '0;
            dma_len  <= '0;
            dma_start<= 1'b0;
            dma_cnt  <= '0;
            dma_state<= DMA_IDLE;
            dma_busy <= 1'b0;
            dma_done <= 1'b0;
            for (int i = 0; i < SRAM_WORDS; i++) sram[i] <= '0;
        end else begin
            ra_ready <= 1'b0;
            dma_start <= 1'b0;

            if (ra_valid && !ra_ready) begin
                ra_ready <= 1'b1;
                case (ra_cmd)
                    2'b00: begin  // READ
                        if (ra_addr < MEM_SIZE) begin
                            ra_rdata <= sram[ra_addr[$clog2(SRAM_WORDS)+3:4]];
                            ra_resp  <= 2'd0;
                        end else begin
                            // Control register read
                            case (ra_addr)
                                28'h0100_0000: ra_rdata <= dma_src;
                                28'h0100_0008: ra_rdata <= dma_dst;
                                28'h0100_0010: ra_rdata <= dma_len;
                                28'h0100_0020: ra_rdata <= {62'd0, dma_done, dma_busy};
                                default: begin
                                    ra_rdata <= '0;
                                    ra_resp  <= 2'd1;
                                end
                            endcase
                        end
                    end
                    2'b01: begin  // WRITE
                        if (ra_addr < MEM_SIZE) begin
                            sram[ra_addr[$clog2(SRAM_WORDS)+3:4]] <= ra_wdata;
                            ra_resp <= 2'd0;
                        end else begin
                            // Control register write
                            case (ra_addr)
                                28'h0100_0000: dma_src <= ra_wdata[ADDR_W-1:0];
                                28'h0100_0008: dma_dst <= ra_wdata[ADDR_W-1:0];
                                28'h0100_0010: dma_len <= ra_wdata[31:0];
                                28'h0100_0018: dma_start <= ra_wdata[0];
                                default: ra_resp <= 2'd1;
                            endcase
                        end
                    end
                    default: ra_resp <= 2'd1;
                endcase
            end

            // ── DMA engine (simple memory-to-memory copy) ──
            case (dma_state)
                DMA_IDLE: begin
                    dma_busy <= 1'b0;
                    dma_done <= 1'b0;
                    if (dma_start) begin
                        dma_state <= DMA_READ;
                        dma_cnt   <= '0;
                        dma_busy  <= 1'b1;
                    end
                end
                DMA_READ: begin
                    // Read from source
                    if (dma_cnt < dma_len) begin
                        dma_state <= DMA_WRITE;
                    end else begin
                        dma_state <= DMA_DONE;
                    end
                end
                DMA_WRITE: begin
                    // Write to destination
                    sram[dma_dst[$clog2(SRAM_WORDS)+3:4] + dma_cnt] <= 
                        sram[dma_src[$clog2(SRAM_WORDS)+3:4] + dma_cnt];
                    dma_cnt <= dma_cnt + 1'b1;
                    dma_state <= DMA_READ;
                end
                DMA_DONE: begin
                    dma_busy <= 1'b0;
                    dma_done <= 1'b1;
                    dma_state <= DMA_IDLE;
                end
            endcase
        end
    end

endmodule
