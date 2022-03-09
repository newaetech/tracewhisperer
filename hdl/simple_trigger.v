`default_nettype none
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: NewAE
// Engineer: Jean-Pierre Thibault
// 
// Create Date: 
// Design Name: 
// Module Name: simple_trigger
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module simple_trigger (
   input  wire         reset_i,
   input  wire         fe_clk,
   output reg          O_trigger,

   input  wire         I_trigger_enable,
   input  wire         I_capture_off,
   output wire         O_capture_enable_pulse,

   // from pattern match block:
   input  wire         I_match,

   // to/from capture block:
   input  wire         I_capturing,
   output wire         O_capture_enable
);

   (* ASYNC_REG = "TRUE" *) reg  trigger_enable_r;
   reg  capturing_r;
   wire capture_done;
   wire capture_enable_start;
   reg  capture_enable_reg;
   reg  capture_enable_reg2;
   reg  capture_enable_pulse;


   always @ (posedge fe_clk) begin
       trigger_enable_r <= I_trigger_enable;
       if (I_match && trigger_enable_r)
           O_trigger <= 1'b1;
       else
           O_trigger <= 1'b0;
   end


   assign capture_done = I_capture_off? O_trigger : !I_capturing & capturing_r;


   always @ (posedge fe_clk) begin
      if (reset_i) begin
         capturing_r <= 1'b0;
         capture_enable_reg <= 1'b0;
         capture_enable_reg2 <= 1'b0;
         capture_enable_pulse <= 1'b0;
      end

      else begin
         capturing_r <= I_capturing;
         capture_enable_reg2 <= capture_enable_reg;

         if (capture_enable_reg & !capture_enable_reg2)
            capture_enable_pulse <= 1'b1;
         else
            capture_enable_pulse <= 1'b0;

         if (capture_done)
            capture_enable_reg <= 1'b0;
         else if (I_match)
            capture_enable_reg <= 1'b1;

      end
   end

   assign capture_enable_start = I_match;
   assign O_capture_enable = (capture_enable_start | capture_enable_reg) & !I_capture_off;
   assign O_capture_enable_pulse = capture_enable_pulse;


endmodule

`default_nettype wire
