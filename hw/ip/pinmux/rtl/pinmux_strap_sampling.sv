// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module pinmux_strap_sampling
  import pinmux_pkg::*;
  import pinmux_reg_pkg::*;
  import prim_pad_wrapper_pkg::*;
#(
  // Taget-specific pinmux configuration passed down from the
  // target-specific top-level.
  parameter target_cfg_t TargetCfg = DefaultTargetCfg
) (
  input                            clk_i,
  input                            rst_ni,
  input prim_mubi_pkg::mubi4_t     scanmode_i,
  // To padring side
  output pad_attr_t [NumIOs-1:0]   attr_padring_o,
  output logic      [NumIOs-1:0]   out_padring_o,
  output logic      [NumIOs-1:0]   oe_padring_o,
  input  logic      [NumIOs-1:0]   in_padring_i,
  // To core side
  input  pad_attr_t [NumIOs-1:0]   attr_core_i,
  input  logic      [NumIOs-1:0]   out_core_i,
  input  logic      [NumIOs-1:0]   oe_core_i,
  output logic      [NumIOs-1:0]   in_core_o,
  // Used for TAP qualification
  input  logic                     strap_en_i,
  input  lc_ctrl_pkg::lc_tx_t      lc_dft_en_i,
  input  lc_ctrl_pkg::lc_tx_t      lc_hw_debug_en_i,
  // Sampled values for DFT straps
  output dft_strap_test_req_t      dft_strap_test_o,
  // Hold tap strap select
  input                            dft_hold_tap_sel_i,
  // Qualified JTAG signals for TAPs
  output jtag_pkg::jtag_req_t      lc_jtag_o,
  input  jtag_pkg::jtag_rsp_t      lc_jtag_i,
  output jtag_pkg::jtag_req_t      rv_jtag_o,
  input  jtag_pkg::jtag_rsp_t      rv_jtag_i,
  output jtag_pkg::jtag_req_t      dft_jtag_o,
  input  jtag_pkg::jtag_rsp_t      dft_jtag_i
);


  /////////////////////////////////////
  // Life cycle signal synchronizers //
  /////////////////////////////////////

  lc_ctrl_pkg::lc_tx_t [1:0] lc_hw_debug_en;
  lc_ctrl_pkg::lc_tx_t [1:0] lc_dft_en;
  prim_mubi_pkg::mubi4_t [0:0] scanmode;

  prim_mubi4_sync #(
    .NumCopies(1),
    .AsyncOn(0)
  ) u_por_scanmode_sync (
    .clk_i(1'b0),  // unused clock
    .rst_ni(1'b1), // unused reset
    .mubi_i(scanmode_i),
    .mubi_o(scanmode)
  );

  prim_lc_sync #(
    .NumCopies(2)
  ) u_prim_lc_sync_rv (
    .clk_i,
    .rst_ni,
    .lc_en_i(lc_hw_debug_en_i),
    .lc_en_o(lc_hw_debug_en)
  );
  prim_lc_sync #(
    .NumCopies(2)
  ) u_prim_lc_sync_dft (
    .clk_i,
    .rst_ni,
    .lc_en_i(lc_dft_en_i),
    .lc_en_o(lc_dft_en)
  );

  //////////////////////////
  // Strap Sampling Logic //
  //////////////////////////

  logic dft_strap_valid_d, dft_strap_valid_q;
  logic lc_strap_sample_en, rv_strap_sample_en, dft_strap_sample_en;
  logic [NTapStraps-1:0] tap_strap_d, tap_strap_q;
  logic [NDFTStraps-1:0] dft_strap_d, dft_strap_q;

  // The LC strap at index 0 has a slightly different
  // enable condition than the DFT strap at index 1.
  assign tap_strap_d[0] = (lc_strap_sample_en) ? in_padring_i[TargetCfg.tap_strap0_idx] :
                                                 tap_strap_q[0];
  assign tap_strap_d[1] = (rv_strap_sample_en) ? in_padring_i[TargetCfg.tap_strap1_idx] :
                                                 tap_strap_q[1];

  // We're always using the DFT strap sample enable for the DFT straps.
  assign dft_strap_d = (dft_strap_sample_en) ? {in_padring_i[TargetCfg.dft_strap1_idx],
                                                in_padring_i[TargetCfg.dft_strap0_idx]} :
                                               dft_strap_q;

  assign dft_strap_valid_d = dft_strap_sample_en | dft_strap_valid_q;
  assign dft_strap_test_o.valid  = dft_strap_valid_q;
  assign dft_strap_test_o.straps = dft_strap_q;


  // During dft enabled states, we continously sample all straps unless
  // told not to do so by external dft logic
  logic tap_sampling_en;
  logic dft_hold_tap_sel;

  prim_buf #(
    .Width(1)
  ) u_buf_hold_tap (
    .in_i(dft_hold_tap_sel_i),
    .out_o(dft_hold_tap_sel)
  );
  assign tap_sampling_en = (lc_dft_en[0] == lc_ctrl_pkg::On) & ~dft_hold_tap_sel;

  always_comb begin : p_strap_sampling
    lc_strap_sample_en = 1'b0;
    rv_strap_sample_en = 1'b0;
    dft_strap_sample_en = 1'b0;
    // Initial strap sampling pulse from pwrmgr,
    // qualified by life cycle signals.
    // The DFT-mode straps are always sampled only once.
    if (strap_en_i) begin
      if (lc_dft_en[0] == lc_ctrl_pkg::On) begin
        dft_strap_sample_en = 1'b1;
      end
    end
    // In DFT-enabled life cycle states we continously
    // sample the TAP straps to be able to switch back and
    // forth between different TAPs.
    if (strap_en_i || tap_sampling_en) begin
      lc_strap_sample_en = 1'b1;
      if (lc_hw_debug_en[0] == lc_ctrl_pkg::On) begin
        rv_strap_sample_en = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_strap_sample
    if (!rst_ni) begin
      tap_strap_q         <= '0;
      dft_strap_q         <= '0;
      dft_strap_valid_q   <= 1'b0;
    end else begin
      tap_strap_q         <= tap_strap_d;
      dft_strap_q         <= dft_strap_d;
      dft_strap_valid_q   <= dft_strap_valid_d;
    end
  end

  ///////////////////////
  // TAP Selection Mux //
  ///////////////////////

  logic jtag_en;
  tap_strap_t tap_strap;
  jtag_pkg::jtag_req_t jtag_req, lc_jtag_req, rv_jtag_req, dft_jtag_req;
  jtag_pkg::jtag_rsp_t jtag_rsp, lc_jtag_rsp, rv_jtag_rsp, dft_jtag_rsp;

  // This muxes the JTAG signals to the correct TAP, based on the
  // sampled straps. Further, the individual JTAG signals are gated
  // using the corresponding life cycle signal.
  assign tap_strap = tap_strap_t'(tap_strap_q);
  `ASSERT_KNOWN(TapStrapKnown_A, tap_strap)

  always_comb begin : p_tap_mux
    jtag_rsp     = '0;
    // Note that this holds the JTAGs in reset
    // when they are not selected.
    lc_jtag_req  = '0;
    rv_jtag_req  = '0;
    dft_jtag_req = '0;
    // This activates the TDO override further below.
    jtag_en      = 1'b0;

    unique case (tap_strap)
      LcTapSel: begin
        lc_jtag_req = jtag_req;
        jtag_rsp    = lc_jtag_rsp;
        jtag_en     = 1'b1;
      end
      RvTapSel: begin
        if (lc_hw_debug_en[1] == lc_ctrl_pkg::On) begin
          rv_jtag_req = jtag_req;
          jtag_rsp    = rv_jtag_rsp;
          jtag_en     = 1'b1;
        end
      end
      DftTapSel: begin
        if (lc_dft_en[1] == lc_ctrl_pkg::On) begin
          dft_jtag_req = jtag_req;
          jtag_rsp     = dft_jtag_rsp;
          jtag_en      = 1'b1;
        end
      end
      default: ;
    endcase // tap_strap_t'(tap_strap_q)
  end

  // Insert hand instantiated buffers for
  // these signals to prevent further optimization.
  pinmux_jtag_buf u_pinmux_jtag_buf_lc (
    .req_i(lc_jtag_req),
    .req_o(lc_jtag_o),
    .rsp_i(lc_jtag_i),
    .rsp_o(lc_jtag_rsp)
  );
  pinmux_jtag_buf u_pinmux_jtag_buf_rv (
    .req_i(rv_jtag_req),
    .req_o(rv_jtag_o),
    .rsp_i(rv_jtag_i),
    .rsp_o(rv_jtag_rsp)
  );
  pinmux_jtag_buf u_pinmux_jtag_buf_dft (
    .req_i(dft_jtag_req),
    .req_o(dft_jtag_o),
    .rsp_i(dft_jtag_i),
    .rsp_o(dft_jtag_rsp)
  );

  //////////////////////
  // TAP Input Muxes  //
  //////////////////////

  // Inputs connections
  assign jtag_req.tck    = in_padring_i[TargetCfg.tck_idx];
  assign jtag_req.tms    = in_padring_i[TargetCfg.tms_idx];
  assign jtag_req.tdi    = in_padring_i[TargetCfg.tdi_idx];

  // Note that this resets the selected TAP controller in
  // scanmode. If the TAP controller needs to be active during
  // reset, this reset bypass needs to be adapted accordingly.
  prim_clock_mux2 #(
    .NoFpgaBufG(1'b1)
  ) u_rst_por_aon_n_mux (
    .clk0_i(in_padring_i[TargetCfg.trst_idx]),
    .clk1_i(rst_ni),
    .sel_i(prim_mubi_pkg::mubi4_test_true_strict(scanmode[0])),
    .clk_o(jtag_req.trst_n)
  );

  // Input tie-off muxes and output overrides
  for (genvar k = 0; k < NumIOs; k++) begin : gen_input_tie_off
    if (k == TargetCfg.tck_idx  ||
        k == TargetCfg.tms_idx  ||
        k == TargetCfg.trst_idx ||
        k == TargetCfg.tdi_idx  ||
        k == TargetCfg.tdo_idx) begin : gen_jtag_signal

      // Tie off inputs.
      assign in_core_o[k] = (jtag_en) ? 1'b0 : in_padring_i[k];

      if (k == TargetCfg.tdo_idx) begin : gen_output_mux
        // Override TDO output.
        assign out_padring_o[k] = (jtag_en) ? jtag_rsp.tdo    : out_core_i[k];
        assign oe_padring_o[k]  = (jtag_en) ? jtag_rsp.tdo_oe : oe_core_i[k];
      end else begin : gen_output_tie_off
        // Make sure these pads are set to high-z.
        assign out_padring_o[k] = (jtag_en) ? 1'b0 : out_core_i[k];
        assign oe_padring_o[k]  = (jtag_en) ? 1'b0 : oe_core_i[k];
      end

      // Also reset all corresponding pad attributes to the default ('0) when JTAG is enabled.
      // This disables functional pad features that may have been set, e.g., pull-up/pull-down.
      assign attr_padring_o[k] = (jtag_en) ? '0 : attr_core_i[k];

    end else begin : gen_other_inputs
      assign attr_padring_o[k] = attr_core_i[k];
      assign in_core_o[k]      = in_padring_i[k];
      assign out_padring_o[k]  = out_core_i[k];
      assign oe_padring_o[k]   = oe_core_i[k];
    end
  end

  ////////////////
  // Assertions //
  ////////////////

  `ASSERT_INIT(tck_idxRange_A,  TargetCfg.tck_idx  >= 0 && TargetCfg.tck_idx  < NumIOs)
  `ASSERT_INIT(tms_idxRange_A,  TargetCfg.tms_idx  >= 0 && TargetCfg.tms_idx  < NumIOs)
  `ASSERT_INIT(trst_idxRange_A, TargetCfg.trst_idx >= 0 && TargetCfg.trst_idx < NumIOs)
  `ASSERT_INIT(tdi_idxRange_A,  TargetCfg.tdi_idx  >= 0 && TargetCfg.tdi_idx  < NumIOs)
  `ASSERT_INIT(tdo_idxRange_A,  TargetCfg.tdo_idx  >= 0 && TargetCfg.tdo_idx  < NumIOs)

  `ASSERT_INIT(tap_strap0_idxRange_A, TargetCfg.tap_strap0_idx >= 0 &&
                                      TargetCfg.tap_strap0_idx < NumIOs)
  `ASSERT_INIT(tap_strap1_idxRange_A, TargetCfg.tap_strap1_idx >= 0 &&
                                      TargetCfg.tap_strap1_idx < NumIOs)
  `ASSERT_INIT(dft_strap0_idxRange_A, TargetCfg.dft_strap0_idx >= 0 &&
                                      TargetCfg.dft_strap0_idx < NumIOs)
  `ASSERT_INIT(dft_strap1_idxRange_A, TargetCfg.dft_strap1_idx >= 0 &&
                                      TargetCfg.dft_strap1_idx < NumIOs)

  // The strap sampling enable input shall be pulsed high exactly once after cold boot.
  `ASSERT(PwrMgrStrapSampleOnce_A, strap_en_i |=> ##0 !strap_en_i [*])

  `ASSERT(RvTapOff0_A,  lc_hw_debug_en_i == lc_ctrl_pkg::Off |-> ##2 rv_jtag_o == '0)
  `ASSERT(DftTapOff0_A, lc_dft_en_i == lc_ctrl_pkg::Off |-> ##2 dft_jtag_o == '0)
  // These assumptions are only used in FPV. They will cause failures in simulations.
  `ASSUME_FPV(RvTapOff1_A,  lc_hw_debug_en_i == lc_ctrl_pkg::Off |-> ##2 rv_jtag_i == '0)
  `ASSUME_FPV(DftTapOff1_A, lc_dft_en_i == lc_ctrl_pkg::Off |-> ##2 dft_jtag_i == '0)
endmodule : pinmux_strap_sampling
