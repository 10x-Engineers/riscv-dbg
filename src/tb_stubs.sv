// =============================================================================
// tb_stubs.sv — Simulation-only stubs for PULP primitive cells and
//               common_cells modules not present in this repo.
//
// Included in the compile list BEFORE the RTL that uses them.
//
// Modules provided:
//   cluster_clock_inverter  — simple inverter (used in dmi_jtag_tap for TCK)
//   pulp_clock_mux2         — 2-input clock mux (used in dmi_jtag_tap for DFT)
//   cdc_2phase              — 2-phase req/ack CDC (used in dmi_cdc)
//   fifo_v2                 — simple 2-entry FIFO (used in dm_csrs)
// =============================================================================

// -----------------------------------------------------------------------------
// cluster_clock_inverter
// Just a combinational inverter.  The RTL uses it for TCK edge alignment.
// -----------------------------------------------------------------------------
module cluster_clock_inverter (
    input  logic clk_i,
    output logic clk_o
);
    assign clk_o = ~clk_i;
endmodule

// -----------------------------------------------------------------------------
// pulp_clock_mux2
// 2-input glitch-free clock mux.  In simulation we model it combinatorially.
// clk_sel_i == 0 → clk0_i, clk_sel_i == 1 → clk1_i.
// In this TB testmode_i is always tied to 0, so clk0_i (inverted TCK) is
// always selected, which is the correct functional path.
// -----------------------------------------------------------------------------
module pulp_clock_mux2 (
    input  logic clk0_i,
    input  logic clk1_i,
    input  logic clk_sel_i,
    output logic clk_o
);
    assign clk_o = clk_sel_i ? clk1_i : clk0_i;
endmodule

// -----------------------------------------------------------------------------
// cdc_2phase  (parameterised on data type T)
//
// A synthesisable 2-phase req/ack handshake CDC.
// Protocol (source side):
//   src_valid_i asserted with src_data_i  → src_ready_o pulses when accepted
// Protocol (destination side):
//   dst_valid_o asserted with dst_data_o  → dst_ready_i must be asserted to
//                                           consume and allow next transfer
//
// In this simplified simulation model we use a single flop stage in each
// direction.  This is functionally correct for a TB where TCK << clk
// (JTAG driver runs at 50 MHz, system clock at 100 MHz).
// -----------------------------------------------------------------------------
module cdc_2phase #(
    parameter type T = logic [41:0]
) (
    // Source (sender) side
    input  logic src_rst_ni,
    input  logic src_clk_i,
    input  T     src_data_i,
    input  logic src_valid_i,
    output logic src_ready_o,

    // Destination (receiver) side
    input  logic dst_rst_ni,
    input  logic dst_clk_i,
    output T     dst_data_o,
    output logic dst_valid_o,
    input  logic dst_ready_i
);
    // ── Internal req/ack toggle signals ──────────────────────────────────
    logic  src_req_q, dst_req_q0, dst_req_q1, dst_ack_q0, dst_ack_q1;
    T      src_data_q;

    // Synchroniser from src→dst (2-FF)
    always_ff @(posedge dst_clk_i or negedge dst_rst_ni) begin
        if (!dst_rst_ni) begin
            dst_req_q0 <= 1'b0;
            dst_req_q1 <= 1'b0;
        end else begin
            dst_req_q0 <= src_req_q;
            dst_req_q1 <= dst_req_q0;
        end
    end

    // Synchroniser from dst→src (2-FF)
    logic dst_ack_q;
    always_ff @(posedge src_clk_i or negedge src_rst_ni) begin
        if (!src_rst_ni) begin
            dst_ack_q0 <= 1'b0;
            dst_ack_q1 <= 1'b0;
        end else begin
            dst_ack_q0 <= dst_ack_q;
            dst_ack_q1 <= dst_ack_q0;
        end
    end

    // Source-side req toggle register and data capture
    logic src_pending_q;
    always_ff @(posedge src_clk_i or negedge src_rst_ni) begin
        if (!src_rst_ni) begin
            src_req_q     <= 1'b0;
            src_data_q    <= '0;
            src_pending_q <= 1'b0;
        end else if (src_valid_i && src_ready_o) begin
            src_req_q     <= ~src_req_q;   // toggle to signal new item
            src_data_q    <= src_data_i;
            src_pending_q <= 1'b1;
        end else if (src_pending_q && (dst_ack_q1 == src_req_q)) begin
            src_pending_q <= 1'b0;         // ack received
        end
    end
    assign src_ready_o = !src_pending_q;

    // Destination-side: detect toggle, latch data, produce valid
    logic dst_req_prev_q;
    always_ff @(posedge dst_clk_i or negedge dst_rst_ni) begin
        if (!dst_rst_ni) begin
            dst_req_prev_q <= 1'b0;
            dst_data_o     <= '0;
            dst_valid_o    <= 1'b0;
            dst_ack_q      <= 1'b0;
        end else begin
            dst_req_prev_q <= dst_req_q1;
            if (dst_req_q1 != dst_req_prev_q) begin
                // new item arrived: sample the data that was captured on src side
                dst_data_o  <= src_data_q;
                dst_valid_o <= 1'b1;
            end else if (dst_valid_o && dst_ready_i) begin
                dst_valid_o <= 1'b0;
                dst_ack_q   <= ~dst_ack_q;  // toggle ack
            end
        end
    end

endmodule : cdc_2phase

// -----------------------------------------------------------------------------
// fifo_v2 — parameterised FIFO used by dm_csrs for the DMI response queue.
//
// Port naming follows the common_cells convention used in this RTL:
//   dtype    — data type parameter
//   DEPTH    — number of entries
//   clk_i, rst_ni, flush_i, testmode_i
//   full_o, empty_o, alm_full_o, alm_empty_o
//   data_i, push_i, data_o, pop_i
// -----------------------------------------------------------------------------
module fifo_v2 #(
    parameter type         dtype     = logic [31:0],
    parameter int unsigned DEPTH     = 2
) (
    input  logic  clk_i,
    input  logic  rst_ni,
    input  logic  flush_i,
    input  logic  testmode_i,
    output logic  full_o,
    output logic  empty_o,
    output logic  alm_full_o,
    output logic  alm_empty_o,
    input  dtype  data_i,
    input  logic  push_i,
    output dtype  data_o,
    input  logic  pop_i
);
    localparam int unsigned AddrW = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    dtype mem [0:DEPTH-1];
    logic [AddrW:0] wr_ptr_q, rd_ptr_q;

    wire [AddrW:0] count = wr_ptr_q - rd_ptr_q;

    assign full_o      = (count == AddrW+1'(DEPTH));
    assign empty_o     = (count == '0);
    assign alm_full_o  = (count >= AddrW+1'(DEPTH-1));
    assign alm_empty_o = (count <= 1);
    assign data_o      = mem[rd_ptr_q[AddrW-1:0]];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || flush_i) begin
            wr_ptr_q <= '0;
            rd_ptr_q <= '0;
        end else begin
            if (push_i && !full_o) begin
                mem[wr_ptr_q[AddrW-1:0]] <= data_i;
                wr_ptr_q <= wr_ptr_q + 1'b1;
            end
            if (pop_i && !empty_o) begin
                rd_ptr_q <= rd_ptr_q + 1'b1;
            end
        end
    end

endmodule : fifo_v2
