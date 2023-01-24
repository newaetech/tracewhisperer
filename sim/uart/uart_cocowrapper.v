`timescale 1 ns / 1 ps
`default_nettype none

/***********************************************************************
This file is part of the ChipWhisperer Project. See www.newae.com for more
details, or the codebase at http://www.chipwhisperer.com

Copyright (c) 2022, NewAE Technology Inc. All rights reserved.
Author: Jean-Pierre Thibault <jpthibault@newae.com>

  chipwhisperer is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  chipwhisperer is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU Lesser General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with chipwhisperer.  If not, see <http://www.gnu.org/licenses/>.
*************************************************************************/

module uart_cocowrapper(
    // sync fifo:
    input  wire                         clk, 
    input  wire                         reset_n,

    input  wire [15:0]                  bit_rate,
    input  wire [3:0]                   data_bits,
    input  wire [1:0]                   stop_bits,
    input  wire                         parity_bit,
    input  wire                         parity_enabled,
    input  wire                         parity_accept_errors,
    input  wire                         rxd,
    output wire                         txd,
    output wire                         rxd_syn,
    output wire [8:0]                   rxd_data,
    //input  wire                         rxd_ack,

    // testbench stuff:
    input  wire [31:0]                  errors
);

   parameter pDUMP = 0;

   initial begin
      if (pDUMP) begin
          $dumpfile("uart.fst");
          $dumpvars(0, uart_cocowrapper);
      end
   end

   reg rxd_ack = 1'b0;
   always @(posedge clk) rxd_ack <= rxd_syn;

   uart_core U_dut (
      .clk                      (clk       ),
      .reset_n                  (reset_n   ),
      .bit_rate                 (bit_rate  ),
      .data_bits                (data_bits ),
      .stop_bits                (stop_bits ),
      .parity_bit               (parity_bit),
      .parity_enabled           (parity_enabled),
      .parity_accept_errors     (parity_accept_errors),
      .rxd                      (rxd       ),
      .rxd_syn                  (rxd_syn   ),
      .rxd_data                 (rxd_data  ),
      .rxd_ack                  (rxd_ack   ),
      .rxd_state                (          ),
      .txd                      (txd       ),
      .txd_syn                  (1'b0),
      .txd_data                 (8'd0),
      .txd_ack                  ()
   );

endmodule
`default_nettype wire
