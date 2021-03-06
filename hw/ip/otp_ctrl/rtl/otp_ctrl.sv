// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// OTP Controller top.
//

`include "prim_assert.sv"

module otp_ctrl
  import otp_ctrl_pkg::*;
  import otp_ctrl_reg_pkg::*;
#(
  parameter logic [NumAlerts-1:0] AlertAsyncOn = {NumAlerts{1'b1}}
) (
  input                             clk_i,
  input                             rst_ni,
  // TODO: signals to AST
  // Bus Interface (device)
  input  tlul_pkg::tl_h2d_t         tl_i,
  output tlul_pkg::tl_d2h_t         tl_o,
  // Interrupt Requests
  output logic                      intr_otp_operation_done_o,
  output logic                      intr_otp_error_o,
  // Alerts
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,
  // Power manager interface
  input  pwr_otp_init_req_t         pwr_otp_init_req_i,
  output pwr_otp_init_rsp_t         pwr_otp_init_rsp_o,
  output otp_pwr_state_t            otp_pwr_state_o,
  // Lifecycle transition command interface
  input  lc_otp_program_req_t       lc_otp_program_req_i,
  output lc_otp_program_rsp_t       lc_otp_program_rsp_o,
  // Lifecycle broadcast inputs
  input  lc_tx_t                    lc_escalate_en_i,
  input  lc_tx_t                    lc_provision_en_i,
  input  lc_tx_t                    lc_test_en_i,
  // OTP broadcast outputs
  output otp_lc_data_t              otp_lc_data_o,
  output keymgr_key_t               otp_keymgr_key_o,
  output flash_key_t                otp_flash_key_o
  // TODO: other hardware broadcast outputs
);

  import prim_util_pkg::vbits;

  ////////////////////////
  // Integration Checks //
  ////////////////////////

  // This ensures that we can transfer scrambler data blocks in and out of OTP atomically.
  `ASSERT_INIT(OtpIfWidth_A, OtpIfWidth == ScrmblBlockWidth)

  /////////////
  // Regfile //
  /////////////

  tlul_pkg::tl_h2d_t tl_win_h2d[3];
  tlul_pkg::tl_d2h_t tl_win_d2h[3];

  otp_ctrl_reg_pkg::otp_ctrl_reg2hw_t reg2hw;
  otp_ctrl_reg_pkg::otp_ctrl_hw2reg_t hw2reg;

  otp_ctrl_reg_top u_reg (
    .clk_i,
    .rst_ni,
    .tl_i,
    .tl_o,
    .tl_win_o  ( tl_win_h2d ),
    .tl_win_i  ( tl_win_d2h ),
    .reg2hw    ( reg2hw     ),
    .hw2reg    ( hw2reg     ),
    .devmode_i ( 1'b1       )
  );

  ///////////////////////////////
  // Digests and LC State CSRs //
  ///////////////////////////////

  logic [ScrmblBlockWidth-1:0] unused_digest;
  logic [NumPart-1:0][ScrmblBlockWidth-1:0] part_digest;
  assign hw2reg.creator_sw_cfg_digest = part_digest[CreatorSwCfgIdx];
  assign hw2reg.owner_sw_cfg_digest   = part_digest[OwnerSwCfgIdx];
  assign hw2reg.hw_cfg_digest         = part_digest[HwCfgIdx];
  assign hw2reg.secret0_digest        = part_digest[Secret0Idx];
  assign hw2reg.secret1_digest        = part_digest[Secret1Idx];
  assign hw2reg.secret2_digest        = part_digest[Secret2Idx];
  // LC partition has no digest
  assign unused_digest                = part_digest[LifeCycleIdx];

  // TODO: connect these
  assign hw2reg.lc_state          = '0;
  assign hw2reg.lc_transition_cnt = '0;

  //////////////////////////////
  // Access Defaults and CSRs //
  //////////////////////////////

  part_access_t [NumPart-1:0] part_access_csrs;
  always_comb begin : p_access_control
    // Default (this will be overridden by partition-internal settings).
    part_access_csrs = {{32'(2*NumPart)}{Unlocked}};
    // Propagate CSR read enables down to the SW_CFG partitions.
    if (!reg2hw.creator_sw_cfg_read_lock) part_access_csrs[CreatorSwCfgIdx].read_lock = Locked;
    if (!reg2hw.owner_sw_cfg_read_lock) part_access_csrs[OwnerSwCfgIdx].read_lock = Locked;
    // The SECRET2 partition can only be accessed when provisioning is enabled.
    if (lc_provision_en_i != On) part_access_csrs[Secret2Idx].read_lock = Locked;
    // Permanently lock DAI write access to the life cycle partition
    part_access_csrs[LifeCycleIdx].write_lock = Locked;
  end

  //////////////////////
  // DAI-related CSRs //
  //////////////////////

  logic                         dai_idle;
  logic                         dai_req;
  dai_cmd_e                     dai_cmd;
  logic [OtpByteAddrWidth-1:0]  dai_addr;
  logic [NumDaiWords-1:0][31:0] dai_wdata, dai_rdata;
  logic                         unused_wdata_qe;
  logic                         unused_addr_qe;

  // Any write to this register triggers a DAI command.
  assign dai_req = reg2hw.direct_access_cmd.digest.qe |
                   reg2hw.direct_access_cmd.write.qe  |
                   reg2hw.direct_access_cmd.read.qe;

  assign dai_cmd = {reg2hw.direct_access_cmd.digest.q,
                    reg2hw.direct_access_cmd.write.q,
                    reg2hw.direct_access_cmd.read.q};

  assign dai_addr  = reg2hw.direct_access_address.q;
  assign dai_wdata = reg2hw.direct_access_wdata;
  assign hw2reg.direct_access_rdata = dai_rdata;
  // This write-protects all DAI regs during pending operations.
  assign hw2reg.direct_access_regwen.d = dai_idle;

  // The DAI and the LCI can initiate write transactions, which
  // are critical and we must not power down if such transactions
  // are pending. Hence, we signal the LCI/DAI idle state to the
  // power manager
  logic lci_idle;
  assign otp_pwr_state_o.idle = lci_idle & dai_idle;

  //////////////////////////////////////
  // Ctrl/Status CSRs, Errors, Alerts //
  //////////////////////////////////////

  // Status and error reporting CSRs, error interrupt generation and alerts.
  otp_err_e [NumPart+1:0] part_error;
  logic [NumPart+1:0] part_errors_reduced;
  logic otp_operation_done, otp_error;
  logic otp_fatal_error, otp_check_failed;
  always_comb begin : p_errors_alerts
    hw2reg.err_code = part_error;
    otp_fatal_error = 1'b0;
    otp_check_failed = 1'b0;
    // Aggregate all the errors from the partitions and the DAI/LCI
    for (int k = 0; k < NumPart+2; k++) begin
      // Set the error bit if the error status of the corresponding partition is nonzero.
      // Note that due to the enumeration of the fields in the otp_ctrl_hw2reg_status_reg_t
      // we have to reverse the bitpositions here such that the mapping is correct.
      part_errors_reduced[NumPart+1-k] = |part_error[k];
      // Filter for critical error codes that should not occur in the field.
      otp_fatal_error |= part_error[k] inside {OtpCmdInvErr,
                                               OtpInitErr,
                                               OtpReadUncorrErr,
                                               OtpReadErr,
                                               OtpWriteErr};

      // Filter for integrity and consistency check failures.
      otp_check_failed |= part_error[k] inside {ParityErr,
                                                IntegErr,
                                                CnstyErr,
                                                FsmErr};
    end
  end

  // Assign these to the status register.
  assign hw2reg.status = {part_errors_reduced, dai_idle};
  // If we got an error, we trigger an interrupt.
  assign otp_error = |part_errors_reduced;

  //////////////////////////////////
  // Interrupts and Alert Senders //
  //////////////////////////////////

  prim_intr_hw #(
    .Width(1)
  ) u_intr_esc0 (
    .clk_i,
    .rst_ni,
    .event_intr_i           ( otp_operation_done                      ),
    .reg2hw_intr_enable_q_i ( reg2hw.intr_enable.otp_operation_done.q ),
    .reg2hw_intr_test_q_i   ( reg2hw.intr_test.otp_operation_done.q   ),
    .reg2hw_intr_test_qe_i  ( reg2hw.intr_test.otp_operation_done.qe  ),
    .reg2hw_intr_state_q_i  ( reg2hw.intr_state.otp_operation_done.q  ),
    .hw2reg_intr_state_de_o ( hw2reg.intr_state.otp_operation_done.de ),
    .hw2reg_intr_state_d_o  ( hw2reg.intr_state.otp_operation_done.d  ),
    .intr_o                 ( intr_otp_operation_done_o               )
  );

  prim_intr_hw #(
    .Width(1)
  ) u_intr_esc1 (
    .clk_i,
    .rst_ni,
    .event_intr_i           ( otp_error                      ),
    .reg2hw_intr_enable_q_i ( reg2hw.intr_enable.otp_error.q ),
    .reg2hw_intr_test_q_i   ( reg2hw.intr_test.otp_error.q   ),
    .reg2hw_intr_test_qe_i  ( reg2hw.intr_test.otp_error.qe  ),
    .reg2hw_intr_state_q_i  ( reg2hw.intr_state.otp_error.q  ),
    .hw2reg_intr_state_de_o ( hw2reg.intr_state.otp_error.de ),
    .hw2reg_intr_state_d_o  ( hw2reg.intr_state.otp_error.d  ),
    .intr_o                 ( intr_otp_error_o               )
  );

  prim_alert_sender #(
    .AsyncOn(AlertAsyncOn[0])
  ) u_prim_alert_sender0 (
    .clk_i,
    .rst_ni,
    .alert_i    ( otp_fatal_error ),
    .alert_rx_i ( alert_rx_i[0] ),
    .alert_tx_o ( alert_tx_o[0] )
  );

  prim_alert_sender #(
    .AsyncOn(AlertAsyncOn[1])
  ) u_prim_alert_sender1 (
    .clk_i,
    .rst_ni,
    .alert_i    ( otp_check_failed ),
    .alert_rx_i ( alert_rx_i[1] ),
    .alert_tx_o ( alert_tx_o[1] )
  );

  ////////////////
  // LFSR Timer //
  ////////////////

  // TBD: should we incorporate a timeout in the LFSR counter to cover the case where a
  // partition check never completes due to wedged arbitration (or some other condition
  // induced due to a tampering attempt)? This will likely be constructed in a similar
  // way as the ping timer inside the alert handler.

  logic [NumPart-1:0] integ_chk_req, integ_chk_ack;
  logic [NumPart-1:0] cnsty_chk_req, cnsty_chk_ack;

  ///////////////////////////////
  // OTP Macro and Arbitration //
  ///////////////////////////////

  typedef struct packed {
    prim_otp_cmd_e               cmd;
    logic [OtpSizeWidth-1:0]     size; // Number of native words to write.
    logic [OtpIfWidth-1:0]       wdata;
    logic [OtpAddrWidth-1:0]     addr; // Halfword address.
  } otp_bundle_t;

  logic [NumPart+1:0]          part_otp_arb_req, part_otp_arb_gnt;
  otp_bundle_t                 part_otp_arb_bundle [NumPart+2];
  logic                        otp_arb_valid, otp_arb_ready;
  logic [vbits(NumPart+2)-1:0] otp_arb_idx;
  otp_bundle_t                 otp_arb_bundle;

  // The OTP interface is arbitrated on a per-cycle basis, meaning that back-to-back
  // transactions can be completely independent.
  prim_arbiter_tree #(
    .N(NumPart+2),
    .DW($bits(otp_bundle_t))
  ) u_otp_arb (
    .clk_i,
    .rst_ni,
    .req_i   ( part_otp_arb_req    ),
    .data_i  ( part_otp_arb_bundle ),
    .gnt_o   ( part_otp_arb_gnt    ),
    .idx_o   ( otp_arb_idx         ),
    .valid_o ( otp_arb_valid       ),
    .data_o  ( otp_arb_bundle      ),
    .ready_i ( otp_arb_ready       )
  );

  otp_err_e              part_otp_err;
  logic [OtpIfWidth-1:0] part_otp_rdata;
  logic                  otp_rvalid;
  tlul_pkg::tl_h2d_t     tl_win_h2d_gated;
  tlul_pkg::tl_d2h_t     tl_win_d2h_gated;

  // Life cycle qualification of TL-UL test interface.
  assign tl_win_h2d_gated              = (lc_test_en_i == On) ? tl_win_h2d[$high(tl_win_h2d)] : '0;
  assign tl_win_d2h[$high(tl_win_h2d)] = (lc_test_en_i == On) ? tl_win_d2h_gated : '0;

  prim_otp #(
    .Width(OtpWidth),
    .Depth(OtpDepth),
    .CmdWidth(OtpCmdWidth),
    .ErrWidth(OtpErrWidth)
  ) u_otp (
    .clk_i,
    .rst_ni,
    // Test interface
    .test_tl_i   ( tl_win_h2d_gated     ),
    .test_tl_o   ( tl_win_d2h_gated     ),
    // Read / Write command interface
    .ready_o     ( otp_arb_ready        ),
    .valid_i     ( otp_arb_valid        ),
    .cmd_i       ( otp_arb_bundle.cmd   ),
    .size_i      ( otp_arb_bundle.size  ),
    .addr_i      ( otp_arb_bundle.addr  ),
    .wdata_i     ( otp_arb_bundle.wdata ),
    // Read data out
    .valid_o     ( otp_rvalid           ),
    .rdata_o     ( part_otp_rdata       ),
    .err_o       ( part_otp_err         )
  );

  logic otp_fifo_valid;
  logic [NumPartWidth-1:0] otp_part_idx;
  logic [NumPart+1:0] part_otp_rvalid;

  // We can have up to two OTP commands in flight, hence we size this to be 2 deep.
  // The partitions can unconditionally sink requested data.
  prim_fifo_sync #(
    .Width(NumPartWidth),
    .Depth(2)
  ) u_otp_rsp_fifo (
    .clk_i,
    .rst_ni,
    .clr_i    ( 1'b0           ),
    .wvalid_i ( otp_arb_valid & otp_arb_ready ),
    .wready_o (                ),
    .wdata_i  ( otp_arb_idx    ),
    .rvalid_o ( otp_fifo_valid ),
    .rready_i ( otp_rvalid     ),
    .rdata_o  ( otp_part_idx   ),
    .depth_o  (                )
  );

  // Steer response back to the partition where this request originated.
  always_comb begin : p_rvalid
    part_otp_rvalid = '0;
    part_otp_rvalid[otp_part_idx] = otp_rvalid & otp_fifo_valid;
  end

  // Note that this must be true by construction.
  `ASSERT(OtpRespFifoUnderflow_A, otp_rvalid |-> otp_fifo_valid)

  /////////////////////////////////////////
  // Scrambling Datapath and Arbitration //
  /////////////////////////////////////////

  // Note: as opposed to the OTP arbitration above, we do not perform cycle-wise arbitration, but
  // transaction-wise arbitration. This is implemented using a RR arbiter that acts as a mutex.
  // I.e., each agent (e.g. the DAI or a partition) can request a lock on the mutex. Once granted,
  // the partition can keep the the lock as long as needed for the transaction to complete. The
  // partition must yield its lock by deasserting the request signal for the arbiter to proceed.
  // Since this scheme does not have built-in preemtion, it must be ensured that the agents
  // eventually release their locks for this to be fair.
  typedef struct packed {
    otp_scrmbl_cmd_e             cmd;
    logic  [ConstSelWidth-1:0]   sel;
    logic [ScrmblBlockWidth-1:0] data;
    logic                        valid;
  } scrmbl_bundle_t;

  logic [NumPart:0]            part_scrmbl_mtx_req, part_scrmbl_mtx_gnt;
  scrmbl_bundle_t              part_scrmbl_req_bundle [NumPart+1];
  scrmbl_bundle_t              scrmbl_req_bundle;
  logic [vbits(NumPart+1)-1:0] scrmbl_mtx_idx;
  logic                        scrmbl_mtx_valid;

  // Note that arbiter decisions do not change when backpressured.
  // Hence, the idx_o signal is guaranteed to remain stable until ack'ed.
  prim_arbiter_tree #(
    .N(NumPart+1),
    .DW($bits(scrmbl_bundle_t))
  ) u_scrmbl_mtx (
    .clk_i,
    .rst_ni,
    .req_i   ( part_scrmbl_mtx_req  ),
    .data_i  ( part_scrmbl_req_bundle ),
    .gnt_o   (                        ),
    .idx_o   ( scrmbl_mtx_idx         ),
    .valid_o ( scrmbl_mtx_valid       ),
    .data_o  ( scrmbl_req_bundle      ),
    .ready_i ( 1'b0                   )
  );

  // Since the ready_i signal of the arbiter is statically set to 1'b0 above, we are always in a
  // "backpressure" situation, where the RR arbiter will automatically advance the internal RR state
  // to give the current winner max priority in subsequent cycles in order to keep the decision
  // stable. Rearbitration occurs once the winning agent deasserts its request.
  always_comb begin : p_mutex
    part_scrmbl_mtx_gnt = '0;
    part_scrmbl_mtx_gnt[scrmbl_mtx_idx] = scrmbl_mtx_valid;
  end

  logic [ScrmblBlockWidth-1:0] part_scrmbl_rsp_data;
  logic scrmbl_arb_req_ready, scrmbl_arb_rsp_valid;
  logic [NumPart:0] part_scrmbl_req_ready, part_scrmbl_rsp_valid;

  otp_ctrl_scrmbl u_scrmbl (
    .clk_i,
    .rst_ni,
    .cmd_i   ( scrmbl_req_bundle.cmd   ),
    .sel_i   ( scrmbl_req_bundle.sel   ),
    .data_i  ( scrmbl_req_bundle.data  ),
    .valid_i ( scrmbl_req_bundle.valid ),
    .ready_o ( scrmbl_arb_req_ready    ),
    .data_o  ( part_scrmbl_rsp_data    ),
    .valid_o ( scrmbl_arb_rsp_valid    )
  );

  // steer back responses
  always_comb begin : p_scmrbl_resp
    part_scrmbl_req_ready = '0;
    part_scrmbl_rsp_valid = '0;
    part_scrmbl_req_ready[scrmbl_mtx_idx] = scrmbl_arb_req_ready;
    part_scrmbl_rsp_valid[scrmbl_mtx_idx] = scrmbl_arb_rsp_valid;
  end

  /////////////////////////////
  // Direct Access Interface //
  /////////////////////////////

  logic                           part_init_req;
  logic [NumPart-1:0]             part_init_done;
  part_access_t [NumPart-1:0]     part_access_dai;

  otp_ctrl_dai u_otp_ctrl_dai (
    .clk_i,
    .rst_ni,
    .init_req_i       ( pwr_otp_init_req_i.init               ),
    .init_done_o      ( pwr_otp_init_rsp_o.done               ),
    .part_init_req_o  ( part_init_req                         ),
    .part_init_done_i ( part_init_done                        ),
    .escalate_en_i    ( lc_escalate_en_i                      ),
    .error_o          ( part_error[DaiIdx]                    ),
    .part_access_i    ( part_access_dai                       ),
    .dai_addr_i       ( dai_addr                              ),
    .dai_cmd_i        ( dai_cmd                               ),
    .dai_req_i        ( dai_req                               ),
    .dai_wdata_i      ( dai_wdata                             ),
    .dai_idle_o       ( dai_idle                              ),
    .dai_cmd_done_o   ( otp_operation_done                    ),
    .dai_rdata_o      ( dai_rdata                             ),
    .otp_req_o        ( part_otp_arb_req[DaiIdx]              ),
    .otp_cmd_o        ( part_otp_arb_bundle[DaiIdx].cmd       ),
    .otp_size_o       ( part_otp_arb_bundle[DaiIdx].size      ),
    .otp_wdata_o      ( part_otp_arb_bundle[DaiIdx].wdata     ),
    .otp_addr_o       ( part_otp_arb_bundle[DaiIdx].addr      ),
    .otp_gnt_i        ( part_otp_arb_gnt[DaiIdx]              ),
    .otp_rvalid_i     ( part_otp_rvalid[DaiIdx]               ),
    .otp_rdata_i      ( part_otp_rdata                        ),
    .otp_err_i        ( part_otp_err                          ),
    .scrmbl_mtx_req_o ( part_scrmbl_mtx_req[DaiIdx]           ),
    .scrmbl_mtx_gnt_i ( part_scrmbl_mtx_gnt[DaiIdx]           ),
    .scrmbl_cmd_o     ( part_scrmbl_req_bundle[DaiIdx].cmd    ),
    .scrmbl_sel_o     ( part_scrmbl_req_bundle[DaiIdx].sel    ),
    .scrmbl_data_o    ( part_scrmbl_req_bundle[DaiIdx].data   ),
    .scrmbl_valid_o   ( part_scrmbl_req_bundle[DaiIdx].valid  ),
    .scrmbl_ready_i   ( part_scrmbl_req_ready[DaiIdx]         ),
    .scrmbl_valid_i   ( part_scrmbl_rsp_valid[DaiIdx]         ),
    .scrmbl_data_i    ( part_scrmbl_rsp_data                  )
  );

  ////////////////////////////////////
  // Lifecycle Transition Interface //
  ////////////////////////////////////

  otp_ctrl_lci #(
    .Info(PartInfo[LifeCycleIdx])
  ) u_otp_ctrl_lci (
    .clk_i,
    .rst_ni,
    .escalate_en_i ( lc_escalate_en_i                  ),
    .error_o       ( part_error[LciIdx]                ),
    .lci_idle_o    ( lci_idle                          ),
    // TODO: add LC interface
    .otp_req_o     ( part_otp_arb_req[LciIdx]          ),
    .otp_cmd_o     ( part_otp_arb_bundle[LciIdx].cmd   ),
    .otp_size_o    ( part_otp_arb_bundle[LciIdx].size  ),
    .otp_wdata_o   ( part_otp_arb_bundle[LciIdx].wdata ),
    .otp_addr_o    ( part_otp_arb_bundle[LciIdx].addr  ),
    .otp_gnt_i     ( part_otp_arb_gnt[LciIdx]          ),
    .otp_rvalid_i  ( part_otp_rvalid[LciIdx]           ),
    .otp_rdata_i   ( part_otp_rdata                    ),
    .otp_err_i     ( part_otp_err                      )
  );

  /////////////////////////
  // Partition Instances //
  /////////////////////////

  for (genvar k = 0; k < NumPart; k ++) begin : gen_partitions
    ////////////////////////////////////////////////////////////////////////////////////////////////
    if (PartInfo[k].variant == Unbuffered) begin : gen_unbuffered
      otp_ctrl_part_unbuf #(
        .Info(PartInfo[k])
      ) u_part_unbuf (
        .clk_i,
        .rst_ni,
        .init_req_i    ( part_init_req                ),
        .init_done_o   ( part_init_done[k]            ),
        .escalate_en_i ( lc_escalate_en_i             ),
        .error_o       ( part_error[k]                ),
        .access_i      ( part_access_csrs[k]          ),
        .access_o      ( part_access_dai[k]           ),
        .digest_o      ( part_digest[k]               ),
        // Note: this assumes that partitions with windows always come first.
        .tl_i          ( tl_win_h2d[k]                ),
        .tl_o          ( tl_win_d2h[k]                ),
        .otp_req_o     ( part_otp_arb_req[k]          ),
        .otp_cmd_o     ( part_otp_arb_bundle[k].cmd   ),
        .otp_size_o    ( part_otp_arb_bundle[k].size  ),
        .otp_wdata_o   ( part_otp_arb_bundle[k].wdata ),
        .otp_addr_o    ( part_otp_arb_bundle[k].addr  ),
        .otp_gnt_i     ( part_otp_arb_gnt[k]          ),
        .otp_rvalid_i  ( part_otp_rvalid[k]           ),
        .otp_rdata_i   ( part_otp_rdata               ),
        .otp_err_i     ( part_otp_err                 )
      );

      // Tie off unused connections.
      assign part_scrmbl_mtx_req[k]    = '0;
      assign part_scrmbl_req_bundle[k] = '0;
      // These checks do not exist in this partition type,
      // so we always acknowledge the request.
      assign integ_chk_ack[k]          = 1'b1;
      assign cnsty_chk_ack[k]          = 1'b1;

      // This stops lint from complaining about unused signals.
      logic unused_part_scrmbl_req_ready, unused_part_scrmbl_rsp_valid, unused_part_scrmbl_mtx_gnt;
      logic unused_integ_chk_req, unused_cnsty_chk_req;
      assign unused_part_scrmbl_mtx_gnt   = part_scrmbl_mtx_gnt[k];
      assign unused_part_scrmbl_req_ready = part_scrmbl_req_ready[k];
      assign unused_part_scrmbl_rsp_valid = part_scrmbl_rsp_valid[k];
      assign unused_integ_chk_req         = integ_chk_req[k];
      assign unused_cnsty_chk_req         = cnsty_chk_req[k];

    ////////////////////////////////////////////////////////////////////////////////////////////////
    end else if (PartInfo[k].variant == Buffered) begin : gen_buffered
      otp_ctrl_part_buf #(
        .Info(PartInfo[k])
      ) u_part_buf (
        .clk_i,
        .rst_ni,
        .init_req_i       ( part_init_req                   ),
        .init_done_o      ( part_init_done[k]               ),
        .integ_chk_req_i  ( integ_chk_req[k]                ),
        .integ_chk_ack_o  ( integ_chk_ack[k]                ),
        .cnsty_chk_req_i  ( cnsty_chk_req[k]                ),
        .cnsty_chk_ack_o  ( cnsty_chk_ack[k]                ),
        .escalate_en_i    ( lc_escalate_en_i                ),
        .error_o          ( part_error[k]                   ),
        .access_i         ( part_access_csrs[k]             ),
        .access_o         ( part_access_dai[k]              ),
        .digest_o         ( part_digest[k]                  ),
        .data_o           (                                 ), // TODO: make breakout connections
        .otp_req_o        ( part_otp_arb_req[k]             ),
        .otp_cmd_o        ( part_otp_arb_bundle[k].cmd      ),
        .otp_size_o       ( part_otp_arb_bundle[k].size     ),
        .otp_wdata_o      ( part_otp_arb_bundle[k].wdata    ),
        .otp_addr_o       ( part_otp_arb_bundle[k].addr     ),
        .otp_gnt_i        ( part_otp_arb_gnt[k]             ),
        .otp_rvalid_i     ( part_otp_rvalid[k]              ),
        .otp_rdata_i      ( part_otp_rdata                  ),
        .otp_err_i        ( part_otp_err                    ),
        .scrmbl_mtx_req_o ( part_scrmbl_mtx_req[k]          ),
        .scrmbl_mtx_gnt_i ( part_scrmbl_mtx_gnt[k]          ),
        .scrmbl_cmd_o     ( part_scrmbl_req_bundle[k].cmd   ),
        .scrmbl_sel_o     ( part_scrmbl_req_bundle[k].sel   ),
        .scrmbl_data_o    ( part_scrmbl_req_bundle[k].data  ),
        .scrmbl_valid_o   ( part_scrmbl_req_bundle[k].valid ),
        .scrmbl_ready_i   ( part_scrmbl_req_ready[k]        ),
        .scrmbl_valid_i   ( part_scrmbl_rsp_valid[k]        ),
        .scrmbl_data_i    ( part_scrmbl_rsp_data            )
      );
    end else begin : gen_invalid
      // This is invalid and should break elaboration
      assert_static_in_generate_invalid assert_static_in_generate_invalid();
    end
  end

endmodule : otp_ctrl
