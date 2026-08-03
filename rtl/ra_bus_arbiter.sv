// ============================================================================
// ra_bus_arbiter — RA-BUS Multi-Target Arbiter & Address Decoder
// ============================================================================
// The RA-BUS is the single unified plane connecting host/SBC to ALL G1
// subsystems: PIM Compute Array, Causal Audit Array, Identity Anchor,
// and reserved expansion memory.
//
// Protocol signals (host-facing):
//   ra_cmd[1:0]   — 00:READ 01:WRITE 10:EXECUTE 11:CONFIG
//   ra_addr[31:0] — address space: [31:28] target, [27:0] offset
//   ra_wdata[63:0]— write / execute operand
//   ra_rdata[63:0]— read data output
//   ra_ready      — target ready handshake
//   ra_resp[1:0]  — 00:OK 01:ERROR 10:AUDIT_HALT 11:RETRY
//
// Address map:
//   0x0_xxxxxxx — PIM Compute Array   (compute ops + config)
//   0x1_xxxxxxx — Causal Audit Array  (audit state readback)
//   0x2_xxxxxxx — Identity Anchor     (hash nibble feed)
//   0x3_xxxxxxx — Reserved / Expansion (external memory bus)
//
// License: SPL-G1 dual-track (see LICENSE)
// ============================================================================

module ra_bus_arbiter #(
    parameter int TARGETS = 4,
    parameter int DATA_W  = 64        // v3: RA-BUS data width (64=legacy, 128=expanded)
) (
    // Host side (RA-BUS external)
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ra_valid,
    input  logic [1:0]  ra_cmd,          // READ/WRITE/EXECUTE/CONFIG
    input  logic [31:0] ra_addr,         // [31:28]=target, [27:0]=offset
    input  logic [DATA_W-1:0] ra_wdata,
    output logic [DATA_W-1:0] ra_rdata,
    output logic        ra_ready,
    output logic [1:0]  ra_resp,         // OK/ERROR/AUDIT_HALT/RETRY

    // ── Target 0: PIM Compute Array ──
    output logic        pim_valid,
    output logic [1:0]  pim_cmd,
    output logic [27:0] pim_addr,
    output logic [DATA_W-1:0] pim_wdata,
    output logic        pim_store,
    input  logic [DATA_W-1:0] pim_rdata,
    input  logic        pim_ready,
    input  logic [1:0]  pim_resp,

    // ── Target 1: Causal Audit Array ──
    output logic        audit_valid,
    output logic [1:0]  audit_cmd,
    output logic [27:0] audit_addr,
    output logic [DATA_W-1:0] audit_wdata,
    input  logic [DATA_W-1:0] audit_rdata,
    input  logic        audit_ready,
    input  logic [1:0]  audit_resp,

    // ── Target 2: Identity Anchor ──
    output logic        id_valid,
    output logic [1:0]  id_cmd,
    output logic [27:0] id_addr,
    output logic [DATA_W-1:0] id_wdata,
    input  logic [DATA_W-1:0] id_rdata,
    input  logic        id_ready,
    input  logic [1:0]  id_resp,

    // ── Target 3: Reserved ──
    output logic        ext_valid,
    output logic [1:0]  ext_cmd,
    output logic [27:0] ext_addr,
    output logic [DATA_W-1:0] ext_wdata,
    input  logic [DATA_W-1:0] ext_rdata,
    input  logic        ext_ready,
    input  logic [1:0]  ext_resp
);

    // ── Address decode ──
    logic [1:0] target_sel;
    assign target_sel = ra_addr[29:28];

    // ── Target valid gating ──
    assign pim_valid   = ra_valid && (target_sel == 2'd0);
    assign audit_valid = ra_valid && (target_sel == 2'd1);
    assign id_valid    = ra_valid && (target_sel == 2'd2);
    assign ext_valid   = ra_valid && (target_sel == 2'd3);

    // ── Pass-through commands & addr offsets ──
    assign pim_cmd   = ra_cmd;
    assign audit_cmd = ra_cmd;
    assign id_cmd    = ra_cmd;
    assign ext_cmd   = ra_cmd;

    assign pim_addr   = ra_addr[27:0];
    assign audit_addr = ra_addr[27:0];
    assign id_addr    = ra_addr[27:0];
    assign ext_addr   = ra_addr[27:0];

    assign pim_wdata   = ra_wdata;
    assign audit_wdata = ra_wdata;
    assign id_wdata    = ra_wdata;
    assign ext_wdata   = ra_wdata;

    // pim_store = 1 when WRITE or EXECUTE (not READ)
    assign pim_store = (pim_valid && ra_cmd != 2'b00);

    // ── Response mux (selected target drives bus) ──
    always_comb begin
        case (target_sel)
            2'd0: begin ra_rdata = pim_rdata;   ra_ready = pim_ready;   ra_resp = pim_resp; end
            2'd1: begin ra_rdata = audit_rdata; ra_ready = audit_ready; ra_resp = audit_resp; end
            2'd2: begin ra_rdata = id_rdata;    ra_ready = id_ready;    ra_resp = id_resp; end
            2'd3: begin ra_rdata = ext_rdata;   ra_ready = ext_ready;   ra_resp = ext_resp; end
            default: begin ra_rdata = {(DATA_W){1'b1}}; ra_ready = 1'b1; ra_resp = 2'd1; end
        endcase
    end

endmodule
