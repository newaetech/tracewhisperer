//////////////////////////////////////////////////////////////////////////////////
// Company: NewAE
// Engineer: Jean-Pierre Thibaut
// 
// Create Date: 
// Design Name: 
// Module Name: fe_capture_trace
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: Front-end module, ARM trace-specific logic.
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
`default_nettype none
`include "defines.v"

module fe_capture_trace #(
    parameter pBUFFER_SIZE = 64, // in bits
    parameter pTIMESTAMP_FULL_WIDTH = 16,
    parameter pTIMESTAMP_SHORT_WIDTH = 8,
    parameter pMATCH_RULES = 8
)(
    input  wire usb_clk,
    input  wire reset,

    /* FRONT END CONNECTIONS */
    input  wire trace_clk,
    input  wire [3:0] trace_data,

    /* GENERIC FRONT END CONNECTIONS */
    output wire O_event,
    output wire [1:0] O_data_cmd,
    input  wire [pTIMESTAMP_FULL_WIDTH-1:0] I_fifo_time,
    input  wire [1:0] I_fifo_command,
    input  wire I_fifo_wr,
    output wire [15:0] O_max_short_timestamp,

    /* REGISTER CONNECTIONS */
    output wire O_fifo_fe_status,
    input  wire [2:0] I_trace_width, // supported values: 1/2/4
    input  wire I_reset_sync,
    input  wire I_capture_rules_mode,
    input  wire [pMATCH_RULES-1:0] I_pattern_enable,
    input  wire [pMATCH_RULES-1:0] I_pattern_trig_enable,
    input  wire I_soft_trig_enable,

    input  wire [pBUFFER_SIZE-1:0] I_pattern0, 
    input  wire [pBUFFER_SIZE-1:0] I_pattern1,
    input  wire [pBUFFER_SIZE-1:0] I_pattern2,
    input  wire [pBUFFER_SIZE-1:0] I_pattern3,
    input  wire [pBUFFER_SIZE-1:0] I_pattern4,
    input  wire [pBUFFER_SIZE-1:0] I_pattern5,
    input  wire [pBUFFER_SIZE-1:0] I_pattern6,
    input  wire [pBUFFER_SIZE-1:0] I_pattern7,
    input  wire [pBUFFER_SIZE-1:0] I_mask0,
    input  wire [pBUFFER_SIZE-1:0] I_mask1,
    input  wire [pBUFFER_SIZE-1:0] I_mask2,
    input  wire [pBUFFER_SIZE-1:0] I_mask3,
    input  wire [pBUFFER_SIZE-1:0] I_mask4,
    input  wire [pBUFFER_SIZE-1:0] I_mask5,
    input  wire [pBUFFER_SIZE-1:0] I_mask6,
    input  wire [pBUFFER_SIZE-1:0] I_mask7,

    /* FIFO CONNECTIONS */
    output reg [17:0] O_fifo_data,
    output reg  O_fifo_wr,
    input  wire I_fifo_write_allowed,

    /* TRIGGER CONNECTIONS */
    output wire O_trigger_match,
    input  wire m3_trig

    /* PATTERN MATCHER CONNECTIONS
    output wire [7:0] O_pm_data,
    output wire O_pm_data_valid */

);

   reg [pBUFFER_SIZE-1:0] buffer;
   wire [pBUFFER_SIZE-1:0] revbuffer;
   reg  synchronized;
   reg  [2:0] valid_count;
   reg  word_count;
   reg  [2:0] trace_width_r;
   wire valid_buffer;   
   reg recording;

   wire match;
   wire [pMATCH_RULES-1:0] match_bits;
   reg  [pMATCH_RULES-1:0] match_bits_r;
   reg  [pMATCH_RULES-1:0] match_rule;
   wire [pBUFFER_SIZE-1:0] pattern[pMATCH_RULES-1:0];
   wire [pBUFFER_SIZE-1:0] mask[pMATCH_RULES-1:0];
   reg  m3_trig_r;

   assign mask[0] = I_mask0;
   assign mask[1] = I_mask1;
   assign mask[2] = I_mask2;
   assign mask[3] = I_mask3;
   assign mask[4] = I_mask4;
   assign mask[5] = I_mask5;
   assign mask[6] = I_mask6;
   assign mask[7] = I_mask7;

   assign pattern[0] = I_pattern0;
   assign pattern[1] = I_pattern1;
   assign pattern[2] = I_pattern2;
   assign pattern[3] = I_pattern3;
   assign pattern[4] = I_pattern4;
   assign pattern[5] = I_pattern5;
   assign pattern[6] = I_pattern6;
   assign pattern[7] = I_pattern7;


   assign O_fifo_fe_status = synchronized;
   assign O_event = I_capture_rules_mode? match : recording & valid_buffer;
   assign O_data_cmd = I_capture_rules_mode? `FE_FIFO_CMD_DATA : `FE_FIFO_CMD_STAT;
   assign O_max_short_timestamp = 2**`FE_FIFO_SHORTTIME_LEN-1;

   assign O_trigger_match = (m3_trig & !m3_trig_r & I_soft_trig_enable) ||
                            ( |(match_bits & I_pattern_trig_enable)  & !(|(match_bits_r & I_pattern_trig_enable)) );


   // shift trace data into buffer:
   always @(posedge trace_clk) begin
      if (reset)
         buffer <= 0;
      else begin
         if (I_trace_width == 3'd4)
            buffer <= {buffer[pBUFFER_SIZE-5:0], trace_data[0], trace_data[1], trace_data[2], trace_data[3]};
         else if (I_trace_width == 3'd2)
            buffer <= {buffer[pBUFFER_SIZE-3:0], trace_data[0], trace_data[1]};
         else
            buffer <= {buffer[pBUFFER_SIZE-2:0], trace_data[0]};
      end
   end

   // fix endianness:
   genvar i;
   generate 
      for (i = 0; i < pBUFFER_SIZE; i = i + 1) begin
         assign revbuffer[i] = buffer[pBUFFER_SIZE-1-i];
      end
   endgenerate 

   // Use sync packets to synchronize ourselves:
   always @(posedge trace_clk) begin
      if (reset) begin
         synchronized <= 1'b0;
         valid_count <= 4'b0;
         trace_width_r <= 3'b0;
      end
      else begin
         trace_width_r <= I_trace_width;
         // allow synchronization to be re-established when trace width is
         // changed (or forced manually):
         if (I_reset_sync || (I_trace_width != trace_width_r)) begin
            synchronized <= 1'b0;
            valid_count <= 4'd0;
         end
         // this catches both half and full sync frames:
         else if (~synchronized && 
                  (revbuffer[pBUFFER_SIZE-1-:16] == 16'h7fff) && 
                  (revbuffer[7:0] == 8'hff) // shorthand to ensure that buffer is full of sync frames
                 ) begin
            synchronized <= 1'b1;
            valid_count <= 4'd1;
         end
         else if (synchronized)
            valid_count <= valid_count + 1; // overflow ok and expected
      end
   end

   // valid_buffer is high when the buffer is byte-aligned: every 2 cycles when
   // I_trace_width = 4, every 4 cycles when I_trace_width is 2, and every 8
   // cycles when I_trace_width is 1.
   assign valid_buffer = synchronized && ( (I_trace_width == 1)? (valid_count % 8 == 0) :
                                           (I_trace_width == 2)? (valid_count % 4 == 0) :
                                           (I_trace_width == 4)? (valid_count % 2 == 0) : 1'b0);

   // Filter out *most* sync frames. When buffer isn't full of sync frames, start pushing out
   // data for capture, and stop once the buffer is full of sync frames again.
   // NOTE: if pBUFFER_SIZE changes, this needs to change too. Can't think of a
   // better way to do this short of more complex parsing logic.
   always @(posedge trace_clk) begin
      if (reset) begin
         recording <= 1'b0;
      end

      else if (valid_buffer) begin
         // start when we *don't* see only sync frames:
         if ( (revbuffer == 64'h7fff_7fff_7fff_7fff) ||
              (revbuffer == 64'hff7f_ff7f_ff7f_ff7f) ||
              (revbuffer == 64'h7fff_ffff_7fff_ffff) ||
              (revbuffer == 64'hff7f_ffff_ff7f_ffff) ||
              (revbuffer == 64'hffff_7fff_ffff_7fff) ||
              (revbuffer == 64'hffff_ff7f_ffff_ff7f) ) begin
            recording <= 1'b0;
         end
         else begin
            recording <= 1'b1;
         end
      end

   end


   // look for match:
   generate 
      for (i = 0; i < pMATCH_RULES; i = i + 1) begin
         assign match_bits[i] = ((revbuffer & mask[i]) == (pattern[i] & mask[i])) && I_pattern_enable[i] && valid_buffer;
      end
   endgenerate 

   assign match = |match_bits;


    // Some addditional delay is required in case a long timestamp needs to be issued.
    // TODO: look if this can be reduced?
    always @ (posedge trace_clk) begin
       if (reset) begin
          match_bits_r <= 0;
          m3_trig_r <= 0;
       end
       else begin
          m3_trig_r <= m3_trig;
          match_bits_r <= match_bits;
          if (match)
             match_rule <= match_bits;
       end
    end


   // FIFO write logic.
   // note: could maybe get away with combinatorial logic here?
   always @(posedge trace_clk) begin
      if (reset) begin
         O_fifo_wr <= 1'b0;
         O_fifo_data <= 0;
      end
      else begin
         // don't overflow the FIFO:
         // Because back-to-back writes are possible, checking sniff_fifo_full may not prevent overflow,
         // and so the last few FIFO entries are wasted :-(
         if (I_fifo_wr & I_fifo_write_allowed) begin
            O_fifo_wr <= 1'b1;
            O_fifo_data[`FE_FIFO_CMD_START +: `FE_FIFO_CMD_BIT_LEN] <= I_fifo_command;
            case (I_fifo_command)
               `FE_FIFO_CMD_DATA: begin
                  O_fifo_data[`FE_FIFO_TIME_START +: `FE_FIFO_SHORTTIME_LEN] <= I_fifo_time[`FE_FIFO_SHORTTIME_LEN-1:0];
                  O_fifo_data[`FE_FIFO_DATA_START +: `FE_FIFO_DATA_LEN] <= match_rule;
               end
               `FE_FIFO_CMD_STAT: begin
                  O_fifo_data[`FE_FIFO_TIME_START +: `FE_FIFO_SHORTTIME_LEN] <= I_fifo_time[`FE_FIFO_SHORTTIME_LEN-1:0];
                  // TODO: will need to adjust line below for different trace widths
                  O_fifo_data[`FE_FIFO_DATA_START +: `FE_FIFO_DATA_LEN] <= revbuffer[43-:`FE_FIFO_DATA_LEN];
               end
               `FE_FIFO_CMD_TIME: begin
                  O_fifo_data[`FE_FIFO_TIME_START +: `FE_FIFO_FULLTIME_LEN] <= I_fifo_time;
               end
            endcase
         end
         else
            O_fifo_wr <= 1'b0;
      end
   end


endmodule
`default_nettype wire