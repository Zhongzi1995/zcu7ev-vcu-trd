//-----------------------------------------------------------------------------
//  (c) Copyright 2016 Xilinx, Inc. All rights reserved.
//
//  This file contains confidential and proprietary information
//  of Xilinx, Inc. and is protected under U.S. and
//  international copyright and other intellectual property
//  laws.
//
//  DISCLAIMER
//  This disclaimer is not a license and does not grant any
//  rights to the materials distributed herewith. Except as
//  otherwise provided in a valid license issued to you by
//  Xilinx, and to the maximum extent permitted by applicable
//  law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
//  WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
//  AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
//  BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
//  INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
//  (2) Xilinx shall not be liable (whether in contract or tort,
//  including negligence, or under any other theory of
//  liability) for any loss or damage of any kind or nature
//  related to, arising under or in connection with these
//  materials, including for any direct, or any indirect,
//  special, incidental, or consequential loss or damage
//  (including loss of data, profits, goodwill, or any type of
//  loss or damage suffered as a result of any action brought
//  by a third party) even if such damage or loss was
//  reasonably foreseeable or Xilinx had been advised of the
//  possibility of the same.
//
//  CRITICAL APPLICATIONS
//  Xilinx products are not designed or intended to be fail-
//  safe, or for use in any application requiring fail-safe
//  performance, such as life-support or safety devices or
//  systems, Class III medical devices, nuclear facilities,
//  applications related to the deployment of airbags, or any
//  other applications that could lead to death, personal
//  injury, or severe property or environmental damage
//  (individually and collectively, "Critical
//  Applications"). Customer assumes the sole risk and
//  liability of any use of Xilinx products in Critical
//  Applications, subject only to applicable laws and
//  regulations governing limitations on product liability.
//
//  THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
//  PART OF THIS FILE AT ALL TIMES. 
//
//----------------------------------------------------------
/*
Module Description:
This module converts 1 pixel-per-clock video input
to 1/2/4 pixel-per-clock at the output. 
------------------------------------------------------------------------------
*/

`timescale 1ps/1ps

(* DowngradeIPIdentifiedWarnings="yes" *)
module v_sdi_rx_vid_bridge_v2_0_0_3g_converter #(
 parameter C_PPC = 1 // Pixel-per-clock: 1, 2, or 4
) (
  input wire                  clk,
  input wire                  rst,
  input wire                  clken,

  // Video Inputs
  input wire [20-1:0]         vid_data_in,            // Input parallel video data.  2 components, 10 bits, 1/2/4 PPC
  input wire                  vid_active_video_in,    // Input active video control signal
  input wire                  vid_vblank_in,          // Input vertical blank
  input wire                  vid_hblank_in,          // Input horizontal blank
  input wire                  vid_field_id_in,        // Input field_id bit

  // Video Outputs
  output wire [20*C_PPC-1:0]  vid_data_out,           // Output parallel video data.  2 components, 10 bits
  output wire                 vid_active_video_out,   // Output active video control signal
  output wire                 vid_vblank_out,         // Output vertical blank
  output wire                 vid_hblank_out,         // Output horizontal blank
  output wire                 vid_field_id_out,       // Output field_id bit
  output wire                 vid_clken               // Output output clock enable
);

// Internal signals
wire clk_active_re;
reg  clk_first_sof;
wire clk_output_en;
reg [1:0] clk_pixel_cnt;
reg [1:0] clk_pixel_cnt_dly1;
reg clk_vid_clken;
reg [1:0] clk_pixel_cnt_comb;

reg [20*C_PPC-1:0] clk_vid_data;
reg [3:0] clk_vid_active;
reg [3:0] clk_vid_vblank;
reg [3:0] clk_vid_hblank;
reg [3:0] clk_vid_field_id;

assign clk_active_re = ~clk_vid_active[3] & vid_active_video_in;
assign clk_output_en = clk_active_re | clk_first_sof;

// Delay inputs
always @(posedge clk) begin
  if (rst) begin
    clk_vid_active   <= 1'b0;
    clk_vid_vblank   <= 1'b0;
    clk_vid_hblank   <= 1'b0;
    clk_vid_field_id <= 1'b0;
    clk_first_sof    <= 1'b0;
  end else if (clken) begin
    clk_vid_active   <= {vid_active_video_in, clk_vid_active[3:1]};
    clk_vid_vblank   <= {vid_vblank_in, clk_vid_vblank[3:1]};
    clk_vid_hblank   <= {vid_hblank_in, clk_vid_hblank[3:1]};
    clk_vid_field_id <= {vid_field_id_in, clk_vid_field_id[3:1]};

    if (clk_active_re) 
      clk_first_sof <= 1'b1; 
  end
end



always @(*)
begin
      clk_pixel_cnt_comb      = 2'h0;
      if(clk_active_re)
          clk_pixel_cnt_comb  = 2'h0;
      else
      begin

      case (C_PPC)
        2: clk_pixel_cnt_comb = clk_pixel_cnt ^ 1'b1; // sequence 0, 1, 0, 1
        4: clk_pixel_cnt_comb = clk_pixel_cnt + 1'b1; // sequence 0, 1, 2, 3
        default: clk_pixel_cnt_comb = 2'b00;          // sequence 0, 0, 0 , 0
      endcase
      end
end

// Pixel counter
// Used to generate clock enable
always @(posedge clk) begin
  // cunhua,fix vid_ce gated by vlbank issue: if (rst | vid_vblank_out) begin
  if (rst ) begin
    clk_pixel_cnt <= 2'b00;
    clk_pixel_cnt_dly1 <= 2'b00;
    clk_vid_data <= 'd0;
  end else if (clken) begin
    clk_pixel_cnt      <= clk_pixel_cnt_comb;
    clk_pixel_cnt_dly1 <= clk_pixel_cnt;

    if (clk_output_en) begin
      clk_vid_data[20*clk_pixel_cnt_comb +: 20] <= vid_data_in;
    end
  end
end

generate
// 2 PPC
if (C_PPC == 2) begin : generate_2ppc_clken
  always @(posedge clk) begin
    if (rst) begin
      clk_vid_clken <= 1'b0;
    end 
    else begin
      if(clken)   
        clk_vid_clken <= clk_pixel_cnt_comb[0];
      else
        clk_vid_clken <= 1'b0;
    end
  end
end
// 4 PPC
else if (C_PPC == 4) begin : generate_4ppc_clken
  always @(posedge clk) begin
    if (rst) begin
      clk_vid_clken <= 1'b0;
    end 
    else begin
      if ((clk_pixel_cnt == 2'b11) & ~(clk_pixel_cnt_dly1 == 2'b11) & clken)
        clk_vid_clken <= 1'b1;
      else 
        clk_vid_clken <= 1'b0;
    end
  end
end
// 1 PPC
else begin : generate_1ppc_clken
  always @(posedge clk) begin
    if (rst) begin
      clk_vid_clken <= 1'b0;
    end 
    else begin
      clk_vid_clken <= clken;
    end
  end
end
endgenerate

// Output assignments
assign vid_data_out         = clk_first_sof ? clk_vid_data[20*C_PPC-1:0] : 'd0;
assign vid_active_video_out = clk_first_sof ? clk_vid_active[4-C_PPC]    : 1'b0;
assign vid_vblank_out       = clk_first_sof ? clk_vid_vblank[4-C_PPC]    : 1'b0;
assign vid_hblank_out       = clk_first_sof ? clk_vid_hblank[4-C_PPC]    : 1'b0;
assign vid_field_id_out     = clk_first_sof ? clk_vid_field_id[4-C_PPC]  : 1'b0;
assign vid_clken            = clk_vid_clken;

endmodule

