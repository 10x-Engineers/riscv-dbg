// Copyright 2026 10xEngineers.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Checks the Debug Spec 1.0 additions through the DMI of dm_top:
// version, dmcs2 and custom space, ndmresetpending, sticky unavail with
// ackunavail, nonexistent harts, keepalive, relaxedpriv, write-only
// program buffer, sbcs reserved bits and SBA autoincrement on bus errors

module tb_dm_top_spec_1p0 #(
  parameter int unsigned NrHarts = 3,
  parameter int unsigned BusWidth = 32
);

  logic clk, rst_n;

  logic ndmreset, ndmreset_ack, dmactive;
  logic [NrHarts-1:0] unavailable_i, keepalive;

  logic dmi_req_valid, dmi_req_ready;
  dm::dmi_req_t dmi_req;
  logic dmi_resp_valid;
  dm::dmi_resp_t dmi_resp;

  // system bus: grants at once, responds one cycle later
  logic                master_req, master_we;
  logic [BusWidth-1:0] master_add, master_wdata;
  logic                master_r_valid, bus_err;

  int unsigned errors;

  initial begin
    clk = 1'b0;
    forever #5ns clk = ~clk;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      master_r_valid <= 1'b0;
    end else begin
      master_r_valid <= master_req;
    end
  end

  dm_top #(
    .NrHarts         ( NrHarts         ),
    .BusWidth        ( BusWidth        ),
    .SelectableHarts ( {NrHarts{1'b1}} )
  ) dut (
    .clk_i                  ( clk                     ),
    .rst_ni                 ( rst_n                   ),
    .next_dm_addr_i         ( '0                      ),
    .testmode_i             ( 1'b0                    ),
    .ndmreset_o             ( ndmreset                ),
    .ndmreset_ack_i         ( ndmreset_ack            ),
    .dmactive_o             ( dmactive                ),
    .debug_req_o            (                         ),
    .keepalive_o            ( keepalive               ),
    .unavailable_i          ( unavailable_i           ),
    .hartinfo_i             ( '0                      ),
    .slave_req_i            ( 1'b0                    ),
    .slave_we_i             ( 1'b0                    ),
    .slave_addr_i           ( '0                      ),
    .slave_be_i             ( '0                      ),
    .slave_wdata_i          ( '0                      ),
    .slave_rdata_o          (                         ),
    .master_req_o           ( master_req              ),
    .master_add_o           ( master_add              ),
    .master_we_o            ( master_we               ),
    .master_wdata_o         ( master_wdata            ),
    .master_be_o            (                         ),
    .master_gnt_i           ( master_req              ),
    .master_r_valid_i       ( master_r_valid          ),
    .master_r_err_i         ( master_r_valid & bus_err ),
    .master_r_other_err_i   ( 1'b0                    ),
    .master_r_rdata_i       ( BusWidth'(32'h1234_5678) ),
    .dmi_rst_ni             ( rst_n                   ),
    .dmi_req_valid_i        ( dmi_req_valid           ),
    .dmi_req_ready_o        ( dmi_req_ready           ),
    .dmi_req_i              ( dmi_req                 ),
    .dmi_resp_valid_o       ( dmi_resp_valid          ),
    .dmi_resp_ready_i       ( 1'b1                    ),
    .dmi_resp_o             ( dmi_resp                )
  );

  task automatic check(input logic ok, input string what);
    if (!ok) begin
      $error("%s", what);
      errors++;
    end
  endtask

  task automatic write_dmi(input logic [7:0] address, input logic [31:0] data);
    if (clk !== 1'b0) begin
      @(negedge clk);
    end
    while (!dmi_req_ready) begin
      @(negedge clk);
    end
    dmi_req.addr  = address[6:0];
    dmi_req.op    = dm::DTM_WRITE;
    dmi_req.data  = data;
    dmi_req_valid = 1'b1;
    @(posedge clk);
    if (!dmi_req_ready) begin
      $fatal(1, "DMI write was not accepted");
    end
    @(negedge clk);
    dmi_req_valid = 1'b0;
    #1ns;
    if (!dmi_resp_valid || dmi_resp.resp != dm::DTM_SUCCESS) begin
      $fatal(1, "DMI write to %02x failed (resp=%0d)", address, dmi_resp.resp);
    end
    @(posedge clk);
  endtask

  task automatic read_dmi(input logic [7:0] address, output logic [31:0] data);
    if (clk !== 1'b0) begin
      @(negedge clk);
    end
    while (!dmi_req_ready) begin
      @(negedge clk);
    end
    dmi_req.addr  = address[6:0];
    dmi_req.op    = dm::DTM_READ;
    dmi_req.data  = '0;
    dmi_req_valid = 1'b1;
    @(posedge clk);
    if (!dmi_req_ready) begin
      $fatal(1, "DMI read was not accepted");
    end
    @(negedge clk);
    dmi_req_valid = 1'b0;
    #1ns;
    if (!dmi_resp_valid || dmi_resp.resp != dm::DTM_SUCCESS) begin
      $fatal(1, "DMI read from %02x failed (resp=%0d)", address, dmi_resp.resp);
    end
    data = dmi_resp.data;
    @(posedge clk);
  endtask

  // dmcontrol write with dmactive set and the given hart selected
  task automatic write_dmcontrol(
    input logic [19:0] hartsel,
    input logic        ndmreset_req  = 1'b0,
    input logic        ackunavail    = 1'b0,
    input logic        setkeepalive  = 1'b0,
    input logic        clrkeepalive  = 1'b0,
    input logic        dmactive_req  = 1'b1
  );
    dm::dmcontrol_t dmcontrol;
    dmcontrol              = '0;
    dmcontrol.hartsello    = hartsel[9:0];
    dmcontrol.hartselhi    = hartsel[19:10];
    dmcontrol.ndmreset     = ndmreset_req;
    dmcontrol.ackunavail   = ackunavail;
    dmcontrol.setkeepalive = setkeepalive;
    dmcontrol.clrkeepalive = clrkeepalive;
    dmcontrol.dmactive     = dmactive_req;
    write_dmi(8'(dm::DMControl), dmcontrol);
  endtask

  task automatic read_dmstatus(output dm::dmstatus_t status);
    logic [31:0] data;
    read_dmi(8'(dm::DMStatus), data);
    status = dm::dmstatus_t'(data);
  endtask

  task automatic wait_sba_idle();
    logic [31:0] data;
    dm::sbcs_t sbcs;
    repeat (20) begin
      read_dmi(8'(dm::SBCS), data);
      sbcs = dm::sbcs_t'(data);
      if (!sbcs.sbbusy) return;
    end
    $fatal(1, "SBA stayed busy");
  endtask

  initial begin
    logic [31:0]    data;
    dm::dmstatus_t  status;
    dm::sbcs_t      sbcs;

    errors        = 0;
    rst_n         = 1'b0;
    ndmreset_ack  = 1'b0;
    unavailable_i = '0;
    bus_err       = 1'b0;
    dmi_req_valid = 1'b0;
    dmi_req       = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    write_dmcontrol(0);

    // #512: version 3
    read_dmstatus(status);
    check(status.version == dm::DbgVersion10, "#512: dmstatus.version is not 3");

    // #404/#506/#406: dmcs2 and the custom space read 0, writes have no effect
    write_dmi(8'(dm::DMCS2), '1);
    read_dmi(8'(dm::DMCS2), data);
    check(data == '0, "#404: dmcs2 does not read 0 after a write");
    read_dmi(8'h1f, data);
    check(data == '0, "#406: custom does not read 0");
    read_dmi(8'h70, data);
    check(data == '0, "#406: custom0 does not read 0");
    read_dmi(8'h7f, data);
    check(data == '0, "#406: custom15 does not read 0");

    // #594: ndmresetpending stays set after ndmreset is lowered, until the ack
    read_dmstatus(status);
    check(!status.ndmresetpending, "#594: ndmresetpending set out of reset");
    write_dmcontrol(0, 1'b1);
    read_dmstatus(status);
    check(status.ndmresetpending, "#594: ndmresetpending not set while ndmreset is 1");
    write_dmcontrol(0, 1'b0);
    read_dmstatus(status);
    check(status.ndmresetpending, "#594: ndmresetpending cleared before the reset ack");
    @(negedge clk);
    ndmreset_ack = 1'b1;
    @(negedge clk);
    ndmreset_ack = 1'b0;
    read_dmstatus(status);
    check(!status.ndmresetpending, "#594: ndmresetpending not cleared by the reset ack");

    // #520: sticky unavail, cleared by ackunavail only while the hart is available
    write_dmcontrol(1);
    read_dmstatus(status);
    check(status.stickyunavail, "#520: dmstatus.stickyunavail is not 1");
    check(status.allrunning && !status.allunavail, "#520: hart 1 not running at start");
    unavailable_i[1] = 1'b1;
    @(posedge clk);
    read_dmstatus(status);
    check(status.allunavail && status.anyunavail && !status.allrunning,
          "#520: unavailable hart 1 not reported unavailable");
    unavailable_i[1] = 1'b0;
    @(posedge clk);
    read_dmstatus(status);
    check(status.allunavail && !status.allrunning,
          "#520: hart 1 unavail did not stick after it became available");
    unavailable_i[1] = 1'b1;
    @(posedge clk);
    write_dmcontrol(1, 1'b0, 1'b1);
    unavailable_i[1] = 1'b0;
    @(posedge clk);
    read_dmstatus(status);
    check(status.allunavail, "#520: ackunavail cleared a hart that was still unavailable");
    write_dmcontrol(1, 1'b0, 1'b1);
    read_dmstatus(status);
    check(!status.allunavail && status.allrunning,
          "#520: ackunavail did not clear an available hart");
    // ackunavail applies to the new hartsel
    unavailable_i[2] = 1'b1;
    @(posedge clk);
    unavailable_i[2] = 1'b0;
    write_dmcontrol(0);
    write_dmcontrol(2, 1'b0, 1'b1);
    read_dmstatus(status);
    check(!status.allunavail, "#520: ackunavail did not apply to the newly written hartsel");

    // nonexistent hart (hartsel 3 of 3 harts) is in no other state
    if (NrHarts == 3) begin
      write_dmcontrol(3);
      read_dmstatus(status);
      check(status.allnonexistent && status.anynonexistent, "hartsel 3 not nonexistent");
      check(!status.allrunning && !status.anyrunning && !status.allhalted &&
            !status.anyhalted && !status.allunavail && !status.anyunavail,
            "nonexistent hart also reported running/halted/unavailable");
    end

    // #592: keepalive through setkeepalive/clrkeepalive, on the new hartsel
    write_dmcontrol(0);
    check(keepalive == '0, "#592: keepalive set out of reset");
    write_dmcontrol(0, 1'b0, 1'b0, 1'b1);
    check(keepalive == NrHarts'(1), "#592: setkeepalive did not set hart 0");
    read_dmi(8'(dm::DMControl), data);
    check(data[5:4] == 2'b00, "#592: setkeepalive/clrkeepalive do not read 0");
    write_dmcontrol(2, 1'b0, 1'b0, 1'b1);
    check(keepalive == NrHarts'(3'b101), "#592: setkeepalive did not apply to new hartsel");
    write_dmcontrol(2, 1'b0, 1'b0, 1'b1, 1'b1);
    check(keepalive == NrHarts'(1), "#592: clrkeepalive did not win over setkeepalive");
    write_dmcontrol(0, 1'b0, 1'b0, 1'b0, 1'b1);
    check(keepalive == '0, "#592: clrkeepalive did not clear hart 0");
    write_dmcontrol(1, 1'b0, 1'b0, 1'b1);
    write_dmcontrol(0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
    @(posedge clk);
    check(keepalive == '0, "#592: dmactive = 0 did not clear keepalive");
    write_dmcontrol(0);

    // #536: relaxedpriv is tied to 0
    write_dmi(8'(dm::AbstractCS), 32'h0000_0800);
    read_dmi(8'(dm::AbstractCS), data);
    check(!data[11], "#536: relaxedpriv does not read 0");

    // #731: the program buffer is write-only, the hart still sees the contents
    write_dmi(8'(dm::ProgBuf0), 32'hdead_beef);
    read_dmi(8'(dm::ProgBuf0), data);
    check(data == '0, "#731: progbuf0 does not read 0");
    check(dut.i_dm_csrs.progbuf_q[0] == 32'hdead_beef, "#731: progbuf0 write was lost");

    // sbcs reserved bits [28:23] read 0, sbaccess is R/W
    sbcs = '0;
    sbcs.zero0    = '1;
    sbcs.sbaccess = 3'd1;
    write_dmi(8'(dm::SBCS), sbcs);
    read_dmi(8'(dm::SBCS), data);
    sbcs = dm::sbcs_t'(data);
    check(sbcs.zero0 == '0, "sbcs reserved bits [28:23] do not read 0");
    check(sbcs.sbaccess == 3'd1, "sbcs.sbaccess is not writable");

    // #507: autoincrement only after a successful access
    sbcs = '0;
    sbcs.sbaccess        = 3'd2;
    sbcs.sbautoincrement = 1'b1;
    write_dmi(8'(dm::SBCS), sbcs);
    write_dmi(8'(dm::SBAddress0), 32'h0000_1000);
    write_dmi(8'(dm::SBData0), 32'h0000_00aa);
    wait_sba_idle();
    read_dmi(8'(dm::SBAddress0), data);
    check(data == 32'h0000_1004, "#507: successful write did not autoincrement sbaddress");
    bus_err = 1'b1;
    write_dmi(8'(dm::SBData0), 32'h0000_00bb);
    wait_sba_idle();
    bus_err = 1'b0;
    read_dmi(8'(dm::SBCS), data);
    sbcs = dm::sbcs_t'(data);
    check(sbcs.sberror == 3'd2, "#507: bus error not reported as sberror 2");
    read_dmi(8'(dm::SBAddress0), data);
    check(data == 32'h0000_1004, "#507: failed write autoincremented sbaddress");

    if (errors != 0) begin
      $fatal(1, "tb_dm_top_spec_1p0: %0d check(s) failed", errors);
    end
    $display("tb_dm_top_spec_1p0: passed");
    $finish;
  end

endmodule
