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


module simple_trigger #(
   parameter pNUM_TRIGGER_WIDTH = 16
)(
   input  wire         reset_i,
   input  wire         fe_clk,
   input  wire         usb_clk, // debug only
   output reg          O_trigger,
   input  wire         I_arm,

   input  wire         I_trigger_enable,
   input  wire         I_capture_off,
   input  wire [pNUM_TRIGGER_WIDTH-1:0] I_num_triggers,
   output reg  [pNUM_TRIGGER_WIDTH-1:0] O_triggers_generated,
   output wire         O_capture_enable_pulse,

   // from pattern match block:
   input  wire         I_match,
   output reg          O_triggering,

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
   reg  arm_r;
   reg  last_trig;

   always @ (posedge fe_clk) begin
       trigger_enable_r <= I_trigger_enable;
       arm_r <= I_arm;
       if (I_match && trigger_enable_r)
           O_trigger <= 1'b1;
       else
           O_trigger <= 1'b0;

       if (I_arm & ~arm_r) begin
           O_triggers_generated <= 0;
           O_triggering <= 0;
           last_trig <= 0;
       end
       else begin
           if (O_triggers_generated < I_num_triggers) begin
               last_trig <= 1'b0;
               O_triggering <= 1;
           end
           else begin
               O_triggering <= 0;
               last_trig <= 1'b1;
           end
           if (O_trigger)
               O_triggers_generated <= O_triggers_generated + 1;
       end
   end

   assign capture_done = I_capture_off? last_trig : !I_capturing & capturing_r;

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

   `ifdef ILA_SIMPLE_TRIGGER
      ila_simple_trigger I_ila_simple_trigger (
         .clk          (usb_clk),                       // input wire clk
         .probe0       (I_match),                       // input wire [0:0]  probe0  
         .probe1       (O_trigger),                     // input wire [0:0]  probe1 
         .probe2       (O_triggers_generated),          // input wire [3:0]  probe2 
         .probe3       (O_triggering),                  // input wire [0:0]  probe3 
         .probe4       (last_trig),                     // input wire [0:0]  probe4 
         .probe5       (capture_done),                  // input wire [0:0]  probe5 
         .probe6       (I_capturing),                   // input wire [0:0]  probe6 
         .probe7       (O_capture_enable),              // input wire [0:0]  probe7 
         .probe8       (I_trigger_enable),              // input wire [0:0]  probe8 
         .probe9       (I_arm),                         // input wire [0:0]  probe9 
         .probe10      (O_capture_enable_pulse)         // input wire [0:0]  probe10
      );
   `endif


endmodule

`default_nettype wire
