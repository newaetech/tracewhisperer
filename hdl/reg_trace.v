//////////////////////////////////////////////////////////////////////////////////
// Company: NewAE
// Engineer: Jean-Pierre Thibault
// 
// Create Date: 
// Design Name: 
// Module Name: reg_trace
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: Register block for trace module. To be paired with
// cw305_usb_reg_fe.v.
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns / 1ps
`include "defines_trace.v"

module reg_trace #(
   parameter pBYTECNT_SIZE = 7,
   parameter pBUFFER_SIZE = 64, // in bits
   parameter pMATCH_RULES = 8,
   parameter pSELECT = `TRACE_REG_SELECT,
   parameter pREGISTERED_READ = 1
)(
   input  wire         reset_i,

// Interface to cw305_usb_reg_fe:
   input  wire                                  usb_clk,
   input  wire [7:0]                            reg_address,  // Address of register
   input  wire [pBYTECNT_SIZE-1:0]              reg_bytecnt,  // Current byte count
   output wire [7:0]                            read_data,       //
   input  wire [7:0]                            write_data,      //
   input  wire                                  reg_read,        // Read flag. One clock cycle AFTER this flag is high
                                                                 // valid data must be present on the read_data bus
   input  wire                                  reg_write,       // Write flag. When high on rising edge valid data is
                                                                 // present on write_data
   input  wire                                  reg_addrvalid,   // Address valid flag

// Interface to top level:
   output reg  [4:0]                            O_clksettings,
   output reg  [1:0]                            O_fe_clk_sel,
   output reg                                   O_trace_en,
   output reg  [7:0]                            O_trace_userio_dir,

// Interface to trace_trigger:
   input  wire                                  I_synchronized,
   input  wire                                  I_swo_cdc_overflow,
   input  wire [31:0]                           I_trigger_frequency,
   input  wire [31:0]                           I_fe_frequency,

   output reg  [pMATCH_RULES-1:0]               O_pattern_enable,
   output reg  [pMATCH_RULES-1:0]               O_pattern_trig_enable,
   output reg  [2:0]                            O_trace_width,
   output reg                                   O_soft_trig_passthru,
   output reg                                   O_soft_trig_enable,
   output reg                                   O_capture_raw,
   output reg                                   O_record_syncs,

   output reg  [pBUFFER_SIZE-1:0]               O_trace_pattern0,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_pattern1,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_pattern2,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_pattern3,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_pattern4,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_pattern5,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_pattern6,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_pattern7,

   output reg  [pBUFFER_SIZE-1:0]               O_trace_mask0,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_mask1,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_mask2,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_mask3,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_mask4,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_mask5,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_mask6,
   output reg  [pBUFFER_SIZE-1:0]               O_trace_mask7,

   input  wire [7:0]                            I_trace_count0,
   input  wire [7:0]                            I_trace_count1,
   input  wire [7:0]                            I_trace_count2,
   input  wire [7:0]                            I_trace_count3,
   input  wire [7:0]                            I_trace_count4,
   input  wire [7:0]                            I_trace_count5,
   input  wire [7:0]                            I_trace_count6,
   input  wire [7:0]                            I_trace_count7,

   input  wire [pBUFFER_SIZE-1:0]               I_matched_data,
   input  wire [pBUFFER_SIZE-1:0]               I_revbuffer,

   output reg                                   O_swo_enable,
   output reg  [15:0]                           O_swo_bitrate_div,
   output reg  [1:0]                            O_uart_stop_bits,
   output reg  [3:0]                            O_uart_data_bits,

   output wire                                  O_reset_sync,
    
   input wire  [22:0]                           I_fe_clock_count,

   output reg                                   uart_reset,
   input  wire [2:0]                            uart_state,

   output reg                                   idelay_reset,
   output reg                                   idelay_inc,
   output reg                                   idelay_ce,
   output reg                                   idelay_ld,
   output reg  [4:0]                            idelay_cnt,
   input  wire [4:0]                            idelay_cnt_out,
   input  wire                                  ref_locked,
   input  wire                                  idelay_ready,

   output wire                                  selected

);


   wire [63:0] name = {8'h65, 8'h63, 8'h61, 8'h72, 8'h54, 8'h6d, 8'h72, 8'h41}; // ASCII for 'ArmTrace'
   reg  [7:0] reg_read_data;
   wire [7:0] rev = 8'h01;
   wire [63:0] trace_count;
   reg  reset_sync;
   reg  reset_sync_r;
   reg  [7:0] read_data_r;
   reg  reg_write_r;

   assign selected = reg_addrvalid & reg_address[7:6] == pSELECT;
   wire [5:0] address = reg_address[5:0];
   wire [31:0] fe_clock_count_extended = {9'b0, I_fe_clock_count};


   //////////////////////////////////
   // read logic:
   //////////////////////////////////

   always @(*) begin
      if (selected && reg_read) begin
         case (address)
            `REG_NAME:                  reg_read_data = name[reg_bytecnt[2:0]*8 +: 8];
            `REG_REV:                   reg_read_data = rev;
            `REG_CLKSETTINGS:           reg_read_data = O_clksettings;

            `REG_PATTERN_ENABLE:        reg_read_data = O_pattern_enable;
            `REG_PATTERN_TRIG_ENABLE:   reg_read_data = O_pattern_trig_enable;
            `REG_TRACE_WIDTH:           reg_read_data = O_trace_width;
            `REG_SOFT_TRIG_PASSTHRU:    reg_read_data = O_soft_trig_passthru;
            `REG_SOFT_TRIG_ENABLE:      reg_read_data = O_soft_trig_enable;
            `REG_CAPTURE_RAW:           reg_read_data = O_capture_raw;

            `REG_SYNCHRONIZED:          reg_read_data = I_synchronized;
            `REG_STAT:                  reg_read_data = I_swo_cdc_overflow;
            `REG_TRIGGER_FREQ:          reg_read_data = I_trigger_frequency[reg_bytecnt[1:0]*8 +: 8];
            `REG_FE_FREQ:               reg_read_data = I_fe_frequency[reg_bytecnt[1:0]*8 +: 8];

            `REG_TRACE_PATTERN0:        reg_read_data = O_trace_pattern0[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_PATTERN1:        reg_read_data = O_trace_pattern1[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_PATTERN2:        reg_read_data = O_trace_pattern2[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_PATTERN3:        reg_read_data = O_trace_pattern3[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_PATTERN4:        reg_read_data = O_trace_pattern4[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_PATTERN5:        reg_read_data = O_trace_pattern5[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_PATTERN6:        reg_read_data = O_trace_pattern6[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_PATTERN7:        reg_read_data = O_trace_pattern7[reg_bytecnt[2:0]*8 +: 8];

            `REG_TRACE_MASK0:           reg_read_data = O_trace_mask0[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_MASK1:           reg_read_data = O_trace_mask1[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_MASK2:           reg_read_data = O_trace_mask2[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_MASK3:           reg_read_data = O_trace_mask3[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_MASK4:           reg_read_data = O_trace_mask4[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_MASK5:           reg_read_data = O_trace_mask5[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_MASK6:           reg_read_data = O_trace_mask6[reg_bytecnt[2:0]*8 +: 8];
            `REG_TRACE_MASK7:           reg_read_data = O_trace_mask7[reg_bytecnt[2:0]*8 +: 8];

            `REG_TRACE_COUNT:           reg_read_data = trace_count[reg_bytecnt[2:0]*8 +: 8];

            `REG_RECORD_SYNCS:          reg_read_data = O_record_syncs;
            `REG_MATCHED_DATA:          reg_read_data = I_matched_data[reg_bytecnt[2:0]*8 +: 8];
            `REG_BUFFER:                reg_read_data = I_revbuffer[reg_bytecnt[2:0]*8 +: 8];

            `REG_SWO_ENABLE:            reg_read_data = O_swo_enable;
            `REG_SWO_BITRATE_DIV:       reg_read_data = O_swo_bitrate_div[reg_bytecnt[0]*8 +: 8];
            `REG_UART_STOP_BITS:        reg_read_data = O_uart_stop_bits;
            `REG_UART_DATA_BITS:        reg_read_data = O_uart_data_bits;

            `REG_TRACE_EN:              reg_read_data = O_trace_en;
            `REG_FE_CLOCK_SEL:          reg_read_data = O_fe_clk_sel;
            `REG_FE_CLOCK_COUNT:        reg_read_data = fe_clock_count_extended[reg_bytecnt[1:0]*8 +: 8];

            `REG_TRACE_USERIO_DIR:      reg_read_data = O_trace_userio_dir;
            `REG_UART:                  reg_read_data = uart_state;

            `REG_TRACE_IDELAY:          reg_read_data = {idelay_cnt_out, 1'b0, idelay_ready, ref_locked};

            default:                    reg_read_data = 0;

         endcase
      end
      else
         reg_read_data = 0;
   end


   // Register output read data to ease timing. If you need data one clock
   // cycle earlier, simply remove this stage.
   always @(posedge usb_clk)
      read_data_r <= reg_read_data;

   assign read_data = pREGISTERED_READ? read_data_r : reg_read_data;

   assign trace_count = {I_trace_count0,
                         I_trace_count1,
                         I_trace_count2,
                         I_trace_count3,
                         I_trace_count4,
                         I_trace_count5,
                         I_trace_count6,
                         I_trace_count7};


   //////////////////////////////////
   // write logic (USB clock domain):
   //////////////////////////////////
   always @(posedge usb_clk) begin
      if (reset_i) begin
         O_clksettings <= 0;
         O_pattern_enable <= 0;
         O_pattern_trig_enable <= 0;
         O_trace_width <= 4;    // default to 4-lane operation, matching default FW setting
         O_soft_trig_passthru <= 1;
         O_soft_trig_enable <= 1;
         O_capture_raw <= 1;
         O_trace_pattern0 <= 0;
         O_trace_pattern1 <= 0;
         O_trace_pattern2 <= 0;
         O_trace_pattern3 <= 0;
         O_trace_pattern4 <= 0;
         O_trace_pattern5 <= 0;
         O_trace_pattern6 <= 0;
         O_trace_pattern7 <= 0;
         O_trace_mask0 <= {pBUFFER_SIZE{1'b1}};
         O_trace_mask1 <= {pBUFFER_SIZE{1'b1}};
         O_trace_mask2 <= {pBUFFER_SIZE{1'b1}};
         O_trace_mask3 <= {pBUFFER_SIZE{1'b1}};
         O_trace_mask4 <= {pBUFFER_SIZE{1'b1}};
         O_trace_mask5 <= {pBUFFER_SIZE{1'b1}};
         O_trace_mask6 <= {pBUFFER_SIZE{1'b1}};
         O_trace_mask7 <= {pBUFFER_SIZE{1'b1}};
         O_swo_bitrate_div <= 7;
         O_swo_enable <= 0;
         O_uart_stop_bits <= 1;
         O_uart_data_bits <= 8;
         O_record_syncs <= 0;
         O_fe_clk_sel <= 0;
         reset_sync <= 0;
         reset_sync_r <= 0;
         uart_reset <= 0;
         O_trace_en <= 0;
         O_trace_userio_dir <= 8'b00000011; // 7-4:trace data inputs; 3:nRESET; 2:TDO/SWO; 1-0:outputs for JTAG to SWD switching
         reg_write_r <= 0;
         idelay_reset <= 1'b0;
         idelay_inc <= 1'b0;
         idelay_ce <= 1'b0;
         idelay_ld <= 1'b0;
         idelay_cnt <= 5'b0;
      end

      else begin
         reg_write_r <= reg_write;
         if (selected && reg_write) begin
            case (address)
               `REG_CLKSETTINGS:        O_clksettings <= write_data;

               `REG_PATTERN_ENABLE:     O_pattern_enable <= write_data[pMATCH_RULES-1:0];
               `REG_PATTERN_TRIG_ENABLE:O_pattern_trig_enable <= write_data[pMATCH_RULES-1:0];
               `REG_TRACE_WIDTH:        O_trace_width <= write_data[2:0];
               `REG_SOFT_TRIG_PASSTHRU: O_soft_trig_passthru <= write_data[0];
               `REG_SOFT_TRIG_ENABLE:   O_soft_trig_enable <= write_data[0];
               `REG_CAPTURE_RAW:        O_capture_raw <= write_data[0];
               `REG_RECORD_SYNCS:       O_record_syncs <= write_data[0];

               `REG_TRACE_PATTERN0:     O_trace_pattern0[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_PATTERN1:     O_trace_pattern1[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_PATTERN2:     O_trace_pattern2[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_PATTERN3:     O_trace_pattern3[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_PATTERN4:     O_trace_pattern4[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_PATTERN5:     O_trace_pattern5[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_PATTERN6:     O_trace_pattern6[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_PATTERN7:     O_trace_pattern7[reg_bytecnt[2:0]*8 +: 8] <= write_data;

               `REG_TRACE_MASK0:        O_trace_mask0[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_MASK1:        O_trace_mask1[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_MASK2:        O_trace_mask2[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_MASK3:        O_trace_mask3[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_MASK4:        O_trace_mask4[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_MASK5:        O_trace_mask5[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_MASK6:        O_trace_mask6[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_TRACE_MASK7:        O_trace_mask7[reg_bytecnt[2:0]*8 +: 8] <= write_data;
               `REG_SWO_ENABLE:         O_swo_enable <= write_data[0];
               `REG_SWO_BITRATE_DIV:    O_swo_bitrate_div[reg_bytecnt[0]*8 +: 8] <= write_data;
               `REG_UART_STOP_BITS:     O_uart_stop_bits <= write_data[1:0];
               `REG_UART_DATA_BITS:     O_uart_data_bits <= write_data[3:0];
               `REG_FE_CLOCK_SEL:       O_fe_clk_sel <= write_data[1:0];
               `REG_TRACE_EN:           O_trace_en <= write_data[0];
               `REG_TRACE_USERIO_DIR:   O_trace_userio_dir <= write_data;
               `REG_TRACE_IDELAY_RESET: idelay_reset <= write_data[0];

            endcase
         end

         // RESYNC register is special:
         if (selected && reg_write && (address == `REG_TRACE_RESET_SYNC))
            reset_sync <= 1'b1;
         else 
            reset_sync <= 1'b0;
         reset_sync_r <= reset_sync;

         // REG_UART register is special:
         if (selected && reg_write && (address == `REG_UART))
            uart_reset <= 1'b1;
         else 
            uart_reset <= 1'b0;

         // REG_TRACE_IDELAY register is special:
         if (selected && reg_write && (address == `REG_TRACE_IDELAY) && ~reg_write_r) begin
            idelay_inc <= write_data[0];
            idelay_ce <= write_data[1];
            idelay_ld <= write_data[2];
            idelay_cnt <= write_data[7:3];
         end
         else begin
            idelay_inc <= 1'b0;
            idelay_ce <= 1'b0;
            idelay_ld <= 1'b0;
         end

      end
   end

   assign O_reset_sync = reset_sync & ~reset_sync_r;

   `ifdef ILA_REG_TRACE
       ila_2 U_reg_ila (
	.clk            (usb_clk),                      // input wire clk
	.probe0         (reg_address[7:0]),             // input wire [7:0]  probe0  
	.probe1         (reg_bytecnt),                  // input wire [6:0]  probe1 
	.probe2         (read_data),                    // input wire [7:0]  probe2 
	.probe3         (write_data),                   // input wire [7:0]  probe3 
	.probe4         (reg_read),                     // input wire [0:0]  probe4 
	.probe5         (reg_write),                    // input wire [0:0]  probe5 
	.probe6         (reg_addrvalid),                // input wire [0:0]  probe6 
	.probe7         (reg_read_data),                // input wire [7:0]  probe7 
	.probe8         (selected),                     // input wire [0:0]  probe8 
	.probe9         (O_pattern_enable),             // input wire [7:0]  probe9
	.probe10        (O_fe_clk_sel)                  // input wire [1:0]  probe10
       );
   `endif

endmodule

`default_nettype wire
