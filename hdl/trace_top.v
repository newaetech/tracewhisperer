/* 
Copyright (c) 2020, NewAE Technology Inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted without restriction. Note that modules within
the project may have additional restrictions, please carefully inspect
additional licenses.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The views and conclusions contained in the software and documentation are those
of the authors and should not be interpreted as representing official policies,
either expressed or implied, of NewAE Technology Inc.
*/

`timescale 1 ns / 1 ps
`default_nettype none
`include "defines_pw.v"
`include "defines_trace.v"

module trace_top #(
  parameter pBYTECNT_SIZE = 7,
  parameter pADDR_WIDTH = 21,
  parameter pBUFFER_SIZE = 64,
  parameter pMATCH_RULES = 8,
  parameter pTRIGGER_DELAY_WIDTH = 20,
  parameter pTRIGGER_WIDTH_WIDTH = 17,
  parameter pNUM_TRIGGER_PULSES = 8,
  parameter pNUM_TRIGGER_WIDTH = 4,
  parameter pCAPTURE_LEN_WIDTH = 32,
  parameter pTIMESTAMP_FULL_WIDTH = 16,
  parameter pTIMESTAMP_SHORT_WIDTH = 8,
  parameter pUSERIO_WIDTH = 4
)(
  input  wire trace_clk_in,
  output wire fe_clk,
  input  wire usb_clk,
  input  wire reset_pin,
  output wire fpga_reset,
  output reg  flash_pattern,

  input wire  target_clk,
  input wire  [22:0] I_fe_clock_count,

  input wire  trigger_clk,
  input wire  trigger_clk_locked,
  output wire trigger_clk_psen,
  output wire trigger_clk_psincdec,
  input  wire trigger_clk_psdone,

  `ifdef __ICARUS__
  // for simulation only:
  input wire [7:0] I_trace_sdr,
  `endif

  // trace:
  input  wire [3:0] trace_data,
  input  wire swo,
  output wire O_trace_trig_out,
  input  wire m3_trig,
  output wire O_soft_trig_passthru,

  // USB:
  inout  wire [7:0]    USB_Data,
  input  wire [pADDR_WIDTH-1:0] USB_Addr,
  input  wire          USB_nRD,
  input  wire          USB_nWE,
  input  wire          USB_nCS,
  output wire          O_data_available,
  input  wire          I_fast_fifo_rdn,

  output wire         O_led_select,
  output wire         O_reverse_tracedata,
  output wire         O_error_flag,

  output wire [6:0]     trig_drp_addr,
  output wire           trig_drp_den,
  output wire [15:0]    trig_drp_din,
  input  wire [15:0]    trig_drp_dout,
  output wire           trig_drp_dwe,
  output wire           trig_drp_reset,


  // USERIO pins: (TraceWhisperer only, unused for CW305)
  input  wire [pUSERIO_WIDTH-1:0]   userio_d,
  output wire [pUSERIO_WIDTH-1:0]   O_userio_pwdriven,
  output wire [pUSERIO_WIDTH-1:0]   O_userio_drive_data,

  // Status LEDs:
  output wire arm,
  output wire capturing,

  // Debug:
  output wire synchronized
);

   parameter pALL_TRIGGER_DELAY_WIDTHS = 24*pNUM_TRIGGER_PULSES;
   parameter pALL_TRIGGER_WIDTH_WIDTHS = 24*pNUM_TRIGGER_PULSES;
   parameter pCAPTURE_DELAY_WIDTH = pTRIGGER_DELAY_WIDTH - 2;

   wire isout;
   wire [7:0] cmdfifo_din;
   wire [7:0] cmdfifo_dout_pre;
   //reg  [7:0] cmdfifo_dout_reg;
   wire [7:0] cmdfifo_dout;
   wire [pBYTECNT_SIZE-1:0]  reg_bytecnt;
   wire [7:0]   write_data;
   wire [7:0]   read_data;
   wire [7:0]   read_data_trace;
   wire [7:0]   read_data_trace_trigger_drp;
   wire [7:0]   read_data_main;
   wire         reg_read;
   wire         reg_write;
   wire         reg_addrvalid;

   wire [1:0]   fe_clk_sel;
   wire         trace_clock_sel;

   wire reset;

   wire [7:0] trace_data_iddr;
   wire [7:0] trace_data_sdr;

   `ifdef __ICARUS__
      assign trace_data_iddr = I_trace_sdr;
   `elsif CW305
      assign trace_data_iddr = 8'b0;
   `else
      genvar i;
      generate 
         for (i = 0; i < 4; i = i + 1) begin: gen_adc_data
            IDDR #(
               .DDR_CLK_EDGE     ("OPPOSITE_EDGE"),
               .INIT_Q1          (0),
               .INIT_Q2          (0),
               .SRTYPE           ("SYNC")
            ) U_trace_data_iddr (
               .Q1               (trace_data_iddr[i]),
               .Q2               (trace_data_iddr[i+4]),
               .D                (trace_data[i]),
               .CE               (1'b1),
               .C                (trace_clk_in),
               .S                (1'b0),
               .R                (1'b0)
            );
         end
      endgenerate
   `endif

   assign trace_data_sdr = trace_clock_sel? trace_data_iddr : {4'b0, trace_data};

   assign USB_Data = isout ? cmdfifo_dout : 8'bZ;
   assign cmdfifo_din = USB_Data;
   assign fpga_reset = reset;

   //always @(posedge usb_clk)
   //   cmdfifo_dout_reg <= cmdfifo_dout_pre;
   //assign cmdfifo_dout = O_board_rev[3]? cmdfifo_dout_reg : cmdfifo_dout_pre;
   assign cmdfifo_dout = cmdfifo_dout_pre;


   `ifdef CW305
      wire [pADDR_WIDTH-pBYTECNT_SIZE-1:0]  reg_address;
      cw305_usb_reg_fe #(
         .pBYTECNT_SIZE    (pBYTECNT_SIZE)
      ) U_usb_reg_main (
         .rst              (reset),
         .usb_clk          (usb_clk), 
         .usb_din          (cmdfifo_din), 
         .usb_dout         (cmdfifo_dout_pre), 
         .usb_rdn          (USB_nRD), 
         .usb_wrn          (USB_nWE),
         .usb_cen          (USB_nCS),
         .usb_addr         (USB_Addr),
         .usb_isout        (isout), 
         .I_drive_data     (usb_drive_data),
         .reg_address      (reg_address), 
         .reg_bytecnt      (reg_bytecnt), 
         .reg_datao        (write_data), 
         .reg_datai        (read_data),
         .reg_read         (reg_read), 
         .reg_write        (reg_write), 
         .reg_addrvalid    (reg_addrvalid)
      );
      assign fe_clk = target_clk;
      assign trace_clock_sel = 1'b0;

   `else // PhyWhisperer platform
      wire [pADDR_WIDTH-1:0]  reg_address;
      usb_reg_main #(
         .pBYTECNT_SIZE    (pBYTECNT_SIZE)
      ) U_usb_reg_main (
         .cwusb_clk        (usb_clk), 
         .cwusb_din        (cmdfifo_din), 
         .cwusb_dout       (cmdfifo_dout_pre), 
         .cwusb_rdn        (USB_nRD), 
         .cwusb_wrn        (USB_nWE),
         .cwusb_cen        (USB_nCS),
         .cwusb_addr       (USB_Addr),
         .cwusb_isout      (isout), 
         .I_drive_data     (usb_drive_data),
         .reg_address      (reg_address), 
         .reg_bytecnt      (reg_bytecnt), 
         .reg_datao        (write_data), 
         .reg_datai        (read_data),
         .reg_read         (reg_read), 
         .reg_write        (reg_write), 
         .reg_addrvalid    (reg_addrvalid)
      );

      assign trace_clock_sel = fe_clk_sel == 2'b01;

      `ifndef __ICARUS__
         wire fe_clk_pre;
         BUFGMUX U_fe_clock_mux1 (
            .I0            (target_clk),
            .I1            (trace_clk_in),
            .S             (fe_clk_sel[0]),
            .O             (fe_clk_pre)
         );

         BUFGMUX U_fe_clock_mux2 (
            .I0            (fe_clk_pre),
            .I1            (usb_clk),
            .S             (fe_clk_sel[1]),
            .O             (fe_clk)
         );

      `else
         assign fe_clk = fe_clk_sel[1]?  usb_clk :
                         fe_clk_sel[0]?  trace_clk_in : 
                                         target_clk;
      `endif

   `endif


   wire [4:0] clksettings; // TODO-later

   wire [pMATCH_RULES-1:0] pattern_enable;
   wire [pMATCH_RULES-1:0] pattern_trig_enable;
   wire [2:0] trace_width;
   wire capture_raw;
   wire record_syncs;

   wire [pBUFFER_SIZE-1:0] trace_pattern0;
   wire [pBUFFER_SIZE-1:0] trace_pattern1;
   wire [pBUFFER_SIZE-1:0] trace_pattern2;
   wire [pBUFFER_SIZE-1:0] trace_pattern3;
   wire [pBUFFER_SIZE-1:0] trace_pattern4;
   wire [pBUFFER_SIZE-1:0] trace_pattern5;
   wire [pBUFFER_SIZE-1:0] trace_pattern6;
   wire [pBUFFER_SIZE-1:0] trace_pattern7;

   wire [pBUFFER_SIZE-1:0] trace_mask0;
   wire [pBUFFER_SIZE-1:0] trace_mask1;
   wire [pBUFFER_SIZE-1:0] trace_mask2;
   wire [pBUFFER_SIZE-1:0] trace_mask3;
   wire [pBUFFER_SIZE-1:0] trace_mask4;
   wire [pBUFFER_SIZE-1:0] trace_mask5;
   wire [pBUFFER_SIZE-1:0] trace_mask6;
   wire [pBUFFER_SIZE-1:0] trace_mask7;

   wire [7:0] trace_count0;
   wire [7:0] trace_count1;
   wire [7:0] trace_count2;
   wire [7:0] trace_count3;
   wire [7:0] trace_count4;
   wire [7:0] trace_count5;
   wire [7:0] trace_count6;
   wire [7:0] trace_count7;

   wire [pBUFFER_SIZE-1:0] matched_data;


   wire [17:0] fifo_in_data;
   wire [17:0] fifo_out_data;
   wire fifo_wr;
   wire fifo_read;
   wire fifo_flush;
   wire fifo_overflow_blocked;
   wire fifo_full;
   wire fifo_empty;
   wire [5:0] fifo_status;
   wire fifo_error_flag;
   wire usb_drive_data;
   wire reg_arm;
   wire capture_while_trig;
   wire [15:0] max_timestamp;

   wire [`FE_SELECT_WIDTH-1:0] fe_select;
   wire reg_main_selected;
   wire reg_trace_selected;

   wire trigger_enable;
   wire soft_trig_enable;
   wire [pNUM_TRIGGER_WIDTH-1:0] num_triggers;
   wire [pALL_TRIGGER_DELAY_WIDTHS-1:0] trigger_delay;
   wire [pALL_TRIGGER_WIDTH_WIDTHS-1:0] trigger_width;
   wire trigger_match;

   wire [pCAPTURE_LEN_WIDTH-1:0] capture_len;
   wire count_writes;
   wire counter_quick_start;
   wire capture_now;
   wire capture_enable_pulse;

   wire fe_event;
   wire [1:0] fe_data_cmd;
   wire [15:0] max_short_timestamp;
   wire [pTIMESTAMP_FULL_WIDTH-1:0] fe_time;
   wire [1:0] fe_command;
   wire fe_fifo_wr;

   wire capture_enable;

   wire [7:0] swo_bitrate_div;
   wire swo_enable;
   wire swo_data_ready;
   wire [7:0] swo_data_byte;
   wire swo_cdc_fifo_overflow;
   reg swo_ack;
   wire [2:0] uart_rx_state;
   wire [3:0] uart_data_bits;
   wire [1:0] uart_stop_bits;
   wire arm_pulse;
   wire reset_sync_from_reg;
   wire timestamps_disable;
   wire clear_errors;

   reg  reg_arm_feclk;
   (* ASYNC_REG = "TRUE" *) reg  [1:0] reg_arm_pipe;

   reg [25:0] timer_heartbeat;
   reg freq_measure;
   reg timer_heartbeat22r;
   wire freq_measure_trigger_clk;
   reg [31:0] trigger_frequency_int;
   reg [31:0] trigger_frequency;
   wire freq_measure_fe_clk;
   reg [31:0] fe_frequency_int;
   reg [31:0] fe_frequency;

   assign O_error_flag = swo_cdc_fifo_overflow || fifo_error_flag;


   reg_trace #(
      .pADDR_WIDTH              (pADDR_WIDTH),
      .pBYTECNT_SIZE            (pBYTECNT_SIZE),
      .pBUFFER_SIZE             (pBUFFER_SIZE),
      .pMATCH_RULES             (pMATCH_RULES)
   ) U_reg_trace (
      .reset_i                  (reset), 
      .usb_clk                  (usb_clk), 
      .reg_address              (reg_address[7:0]), 
      .reg_bytecnt              (reg_bytecnt), 
      .read_data                (read_data_trace), 
      .write_data               (write_data),
      .reg_read                 (reg_read), 
      .reg_write                (reg_write), 
      .reg_addrvalid            (reg_addrvalid),

      .O_clksettings            (clksettings),
      .O_fe_clk_sel             (fe_clk_sel),

      .I_synchronized           (synchronized    ),
      .I_swo_cdc_overflow       (swo_cdc_fifo_overflow),
      .I_trigger_frequency      (trigger_frequency),
      .I_fe_frequency           (fe_frequency),

      .O_pattern_enable         (pattern_enable  ),
      .O_pattern_trig_enable    (pattern_trig_enable),
      .O_trace_width            (trace_width     ),
      .O_soft_trig_passthru     (O_soft_trig_passthru),
      .O_soft_trig_enable       (soft_trig_enable),
      .O_capture_raw            (capture_raw),
      .O_record_syncs           (record_syncs),

      .O_trace_pattern0         (trace_pattern0  ),
      .O_trace_pattern1         (trace_pattern1  ),
      .O_trace_pattern2         (trace_pattern2  ),
      .O_trace_pattern3         (trace_pattern3  ),
      .O_trace_pattern4         (trace_pattern4  ),
      .O_trace_pattern5         (trace_pattern5  ),
      .O_trace_pattern6         (trace_pattern6  ),
      .O_trace_pattern7         (trace_pattern7  ),

      .O_trace_mask0            (trace_mask0     ),
      .O_trace_mask1            (trace_mask1     ),
      .O_trace_mask2            (trace_mask2     ),
      .O_trace_mask3            (trace_mask3     ),
      .O_trace_mask4            (trace_mask4     ),
      .O_trace_mask5            (trace_mask5     ),
      .O_trace_mask6            (trace_mask6     ),
      .O_trace_mask7            (trace_mask7     ),

      .I_trace_count0           (trace_count0    ),
      .I_trace_count1           (trace_count1    ),
      .I_trace_count2           (trace_count2    ),
      .I_trace_count3           (trace_count3    ),
      .I_trace_count4           (trace_count4    ),
      .I_trace_count5           (trace_count5    ),
      .I_trace_count6           (trace_count6    ),
      .I_trace_count7           (trace_count7    ),
      .I_matched_data           (matched_data    ),

      .O_swo_enable             (swo_enable      ),
      .O_swo_bitrate_div        (swo_bitrate_div ),
      .O_uart_stop_bits         (uart_stop_bits  ),
      .O_uart_data_bits         (uart_data_bits  ),

      .O_reverse_tracedata      (O_reverse_tracedata),
      .O_reset_sync             (reset_sync_from_reg),

      .I_fe_clock_count         (I_fe_clock_count),
      .selected                 (reg_trace_selected)
   );

   `ifndef CW305
       reg_mmcm_drp #(
          .pBYTECNT_SIZE    (pBYTECNT_SIZE),
          .pDRP_ADDR        (`REG_TRIGGER_DRP_ADDR),
          .pDRP_DATA        (`REG_TRIGGER_DRP_DATA),
          .pDRP_RESET       (`REG_TRIGGER_DRP_RESET)
       ) U_reg_trigger_drp (
          .reset_i          (reset),
          .clk_usb          (usb_clk),
          .reg_address      (reg_address[7:0]), 
          .reg_bytecnt      (reg_bytecnt), 
          .reg_datao        (read_data_trace_trigger_drp), 
          .reg_datai        (write_data), 
          .reg_read         (reg_read), 
          .reg_write        (reg_write), 
          .selected         (reg_trace_selected),

          .drp_addr         (trig_drp_addr ),
          .drp_den          (trig_drp_den  ),
          .drp_din          (trig_drp_din  ),
          .drp_dout         (trig_drp_dout ),
          .drp_dwe          (trig_drp_dwe  ),
          .drp_reset        (trig_drp_reset)
       ); 
   `else
          assign read_data_trace_trigger_drp = 8'b0;
   `endif


   reg_main #(
      .pBYTECNT_SIZE            (pBYTECNT_SIZE),
      .pNUM_TRIGGER_PULSES      (pNUM_TRIGGER_PULSES),
      .pNUM_TRIGGER_WIDTH       (pNUM_TRIGGER_WIDTH),
      .pCAPTURE_LEN_WIDTH       (pCAPTURE_LEN_WIDTH),
      .pQUICK_START_DEFAULT     (1),
      .pUSERIO_WIDTH            (pUSERIO_WIDTH)
   ) U_reg_main (
      .reset_pin        (reset_pin),
      .fpga_reset       (reset),
      .cwusb_clk        (usb_clk), 
      .reg_address      (reg_address[7:0]), 
      .reg_bytecnt      (reg_bytecnt), 
      .read_data        (read_data_main), 
      .write_data       (write_data),
      .reg_read         (reg_read), 
      .reg_write        (reg_write), 
      .reg_addrvalid    (reg_addrvalid),

      .fe_select        (fe_select),

      .userio_d         (userio_d),
      .O_userio_pwdriven (O_userio_pwdriven),
      .O_userio_drive_data (O_userio_drive_data),

      .I_fifo_data      (fifo_out_data),
      .I_fifo_empty     (fifo_empty),
      .O_fifo_read      (fifo_read),
      .I_fifo_status    (fifo_status),

      .O_data_available (O_data_available),
      .I_fast_fifo_rdn  (I_fast_fifo_rdn),
      .I_usb_cen        (USB_nCS),
      .O_usb_drive_data (usb_drive_data),

      .fe_clk           (fe_clk),
      .O_arm            (arm),
      .O_reg_arm        (reg_arm),
      .O_arm_pulse      (arm_pulse),
      .I_flushing       (fifo_flush),
      .O_capture_len    (capture_len),
      .O_count_writes   (count_writes),
      .O_counter_quick_start (counter_quick_start),
      .O_capture_now    (capture_now),
      .O_timestamps_disable (timestamps_disable),
      .O_capture_while_trig (capture_while_trig),
      .O_max_timestamp  (max_timestamp),
      .I_capture_enable_pulse (capture_enable_pulse),
      .O_board_rev      (),
      .O_led_select     (O_led_select),
      .O_clear_errors   (clear_errors),

      .I_locked1        (1'b0),
      .I_locked2        (trigger_clk_locked),

      // Trigger:
      .O_trigger_delay  (trigger_delay),
      .O_trigger_width  (trigger_width),
      .O_trigger_enable (trigger_enable),
      .O_num_triggers   (num_triggers),

      // Trigger clock phase shift:
      .O_psincdec       (trigger_clk_psincdec),
      .O_psen           (trigger_clk_psen),
      .I_psdone         (trigger_clk_psdone),

      .selected         (reg_main_selected)
   );

   assign read_data = reg_main_selected? read_data_main :
                      reg_trace_selected?  read_data_trace | read_data_trace_trigger_drp : 8'h00;


   `ifndef NOFIFO // for clean compilation
   fifo U_fifo (
      .reset_i                  (reset),
      .cwusb_clk                (usb_clk),
      .fe_clk                   (fe_clk),

      .O_fifo_full              (fifo_full),
      .O_fifo_overflow_blocked  (fifo_overflow_blocked),
      .I_data                   (fifo_in_data),
      .I_wr                     (fifo_wr),

      .I_fifo_read              (fifo_read),
      .I_fifo_flush             (fifo_flush),
      .I_clear_read_flags       (reg_arm),
      .I_clear_write_flags      (reg_arm_feclk),
      .I_clear_errors           (clear_errors),

      .O_data                   (fifo_out_data),
      .O_fifo_status            (fifo_status),
      .O_fifo_empty             (fifo_empty),
      .O_error_flag             (fifo_error_flag),

      .I_custom_fifo_stat_flag  (synchronized)      
   );
   `endif

   // CDC on reg_arm for fifo:
   always @(posedge fe_clk) begin
      if (reset) begin
         reg_arm_feclk <= 0;
         reg_arm_pipe <= 0;
      end
      else begin
         {reg_arm_feclk, reg_arm_pipe} <= {reg_arm_pipe, reg_arm};
      end
   end


   fe_capture_main #(
      .pTIMESTAMP_FULL_WIDTH    (pTIMESTAMP_FULL_WIDTH),
      .pTIMESTAMP_SHORT_WIDTH   (pTIMESTAMP_SHORT_WIDTH),
      .pCAPTURE_LEN_WIDTH       (pCAPTURE_LEN_WIDTH)
   ) U_fe_capture_main (
      .reset_i                  (reset), 
      .cwusb_clk                (usb_clk),
      .fe_clk                   (fe_clk), 
      .trace_clock_sel          (trace_clock_sel),

      .I_timestamps_disable     (timestamps_disable),
      .I_arm                    (arm),
      .I_reg_arm                (reg_arm),
      .I_capture_len            (capture_len),
      .I_count_writes           (count_writes),
      .I_counter_quick_start    (counter_quick_start),
      .I_max_timestamp          (max_timestamp),

      .I_event                  (fe_event),
      .I_data_cmd               (fe_data_cmd),
      .I_max_short_timestamp    (max_short_timestamp),
      .O_fifo_time              (fe_time),
      .O_fifo_command           (fe_command),
      .O_fifo_wr                (fe_fifo_wr),

      .O_fifo_flush             (fifo_flush),
      .O_capture_done           (),
      .I_fifo_overflow_blocked  (fifo_overflow_blocked),
      .I_fifo_full              (fifo_full),
      .I_fifo_empty             (fifo_empty),

      .I_target_trig            (m3_trig),
      .I_capture_while_trig     (capture_while_trig),

      .O_capturing              (capturing),
      .I_capture_enable         (capture_enable)
   );


   fe_capture_trace #(
      .pBUFFER_SIZE             (pBUFFER_SIZE),
      .pTIMESTAMP_FULL_WIDTH    (pTIMESTAMP_FULL_WIDTH),
      .pTIMESTAMP_SHORT_WIDTH   (pTIMESTAMP_SHORT_WIDTH),
      .pMATCH_RULES             (pMATCH_RULES)
   ) U_fe_capture_trace (
      .usb_clk                  (usb_clk),
      .reset                    (reset),
      .swo_clk                  (trigger_clk),

   /* FRONT END CONNECTIONS */
      .fe_clk                   (fe_clk),
      .trace_data               (trace_data_sdr),
      .trace_clock_sel          (trace_clock_sel),

   /* SWO */
      .I_swo_data_ready         (swo_data_ready),
      .I_swo_data               (swo_data_byte),
      .O_swo_cdc_overflow       (swo_cdc_fifo_overflow),
      .I_clear_errors           (clear_errors),

   /* GENERIC FRONT END CONNECTIONS */
      .O_event                  (fe_event),
      .O_data_cmd               (fe_data_cmd),
      .I_fifo_time              (fe_time),
      .I_fifo_command           (fe_command),
      .I_fifo_wr                (fe_fifo_wr),
      .I_capturing              (capturing),
      .O_max_short_timestamp    (max_short_timestamp),

   /* REGISTER CONNECTIONS */
      .O_fifo_fe_status         (synchronized),
      .I_trace_width            (trace_width),
      .I_reset_sync_arm         (arm_pulse),
      .I_reset_sync_reg         (reset_sync_from_reg),
      .I_capture_raw            (capture_raw),
      .I_record_syncs           (record_syncs),
      .I_pattern_enable         (pattern_enable  ),
      .I_pattern_trig_enable    (pattern_trig_enable),
      .I_soft_trig_enable       (soft_trig_enable),
      .I_arm                    (reg_arm_feclk),
      .I_swo_enable             (swo_enable),
      .I_capture_now            (capture_now),

      .I_pattern0               (trace_pattern0),
      .I_pattern1               (trace_pattern1),
      .I_pattern2               (trace_pattern2),
      .I_pattern3               (trace_pattern3),
      .I_pattern4               (trace_pattern4),
      .I_pattern5               (trace_pattern5),
      .I_pattern6               (trace_pattern6),
      .I_pattern7               (trace_pattern7),
      .I_mask0                  (trace_mask0),
      .I_mask1                  (trace_mask1),
      .I_mask2                  (trace_mask2),
      .I_mask3                  (trace_mask3),
      .I_mask4                  (trace_mask4),
      .I_mask5                  (trace_mask5),
      .I_mask6                  (trace_mask6),
      .I_mask7                  (trace_mask7),
      .O_trace_count0           (trace_count0),
      .O_trace_count1           (trace_count1),
      .O_trace_count2           (trace_count2),
      .O_trace_count3           (trace_count3),
      .O_trace_count4           (trace_count4),
      .O_trace_count5           (trace_count5),
      .O_trace_count6           (trace_count6),
      .O_trace_count7           (trace_count7),
      .O_matched_data           (matched_data),

   /* FIFO CONNECTIONS */
      .O_fifo_data              (fifo_in_data),
      .O_fifo_wr                (fifo_wr),

   /* TRIGGER  CONNECTIONS */
      .O_trigger_match          (trigger_match),
      .m3_trig                  (m3_trig)

   /* PATTERN MATCHER CONNECTIONS
      .O_pm_data                (),
      .O_pm_data_valid          () */

   );


   `ifndef CW305
      uart_core U_uart_rx (
         //.clk                      (trace_clk),
         .clk                      (trigger_clk),
         .reset_n                  (~reset),
         // Configuration inputs
         .bit_rate                 ({8'b0, swo_bitrate_div}),
         .data_bits                (uart_data_bits),
         .stop_bits                (uart_stop_bits),
         // External data interface
         .rxd                      (swo),
         .txd                      (),
         // UART Rx
         .rxd_syn                  (swo_data_ready),
         .rxd_data                 (swo_data_byte),
         .rxd_ack                  (swo_ack),
         .rxd_state                (uart_rx_state),
         // UART Tx (unused)
         .txd_syn                  (1'b0),
         .txd_data                 (8'd0),
         .txd_ack                  ()
      );
      always @(posedge trigger_clk) swo_ack <= swo_data_ready;
   `endif

   `ifdef ILA_UART
       ila_uart I_ila_uart (
          .clk          (trigger_clk),          // input wire clk
          .probe0       (swo),                  // input wire [0:0]  probe0  
          .probe1       (swo_bitrate_div),      // input wire [7:0]  probe1 
          .probe2       (swo_data_ready),       // input wire [0:0]  probe2 
          .probe3       (swo_ack),              // input wire [0:0]  probe3 
          .probe4       (uart_rx_state),        // input wire [2:0]  probe4 
          .probe5       (swo_data_byte),        // input wire [7:0]  probe5 
          .probe6       (m3_trig)               // input wire [0:0]  probe6 
       );
   `endif


   pw_trigger #(
      .pCAPTURE_DELAY_WIDTH     (pCAPTURE_DELAY_WIDTH),
      .pTRIGGER_DELAY_WIDTH     (pTRIGGER_DELAY_WIDTH),
      .pTRIGGER_WIDTH_WIDTH     (pTRIGGER_WIDTH_WIDTH),
      .pALL_TRIGGER_DELAY_WIDTHS(pALL_TRIGGER_DELAY_WIDTHS),
      .pALL_TRIGGER_WIDTH_WIDTHS(pALL_TRIGGER_WIDTH_WIDTHS),
      .pNUM_TRIGGER_PULSES      (pNUM_TRIGGER_PULSES),
      .pNUM_TRIGGER_WIDTH       (pNUM_TRIGGER_WIDTH)
   ) U_trigger (
      .reset_i          (reset),
      .trigger_clk      (trigger_clk),
      .fe_clk           (fe_clk),
      .O_trigger        (O_trace_trig_out),
      .I_capture_delay  (18'b0),    // TODO- not needed?
      .I_trigger_delay  (trigger_delay),
      .I_trigger_width  (trigger_width),
      .I_trigger_enable (trigger_enable),
      .I_num_triggers   (num_triggers),
      .O_capture_enable_pulse (capture_enable_pulse),
      .I_match          (trigger_match),
      .I_capturing      (capturing),
      .O_capture_enable (capture_enable)
   );

   // measure fe_clk and trigger_clk frequency: divide clock by 2^23 for frequency measurement
   always @(posedge usb_clk) begin
      if (reset) begin
         timer_heartbeat <= 26'b0;
         timer_heartbeat22r <= 1'b0;
         freq_measure <= 1'b0;
         flash_pattern <= 1'b0;
      end 
      else begin
         timer_heartbeat <= timer_heartbeat +  26'd1;
         timer_heartbeat22r <= timer_heartbeat[22];
         if (timer_heartbeat[22] && ~timer_heartbeat22r)
            freq_measure <= 1'b1;
         else
            freq_measure <= 1'b0;
         if (timer_heartbeat[25])
            flash_pattern <= ~timer_heartbeat[23];
      end
   end

   cdc_pulse U_freq_measure_trigger_clk (
      .reset_i       (reset),
      .src_clk       (usb_clk),
      .src_pulse     (freq_measure),
      .dst_clk       (trigger_clk),
      .dst_pulse     (freq_measure_trigger_clk)
   );

   cdc_pulse U_freq_measure_fe_clk (
      .reset_i       (reset),
      .src_clk       (usb_clk),
      .src_pulse     (freq_measure),
      .dst_clk       (fe_clk),
      .dst_pulse     (freq_measure_fe_clk)
   );

   always @(posedge trigger_clk) begin
      if (freq_measure_trigger_clk) begin
         trigger_frequency_int <= 32'd1;
         trigger_frequency <= trigger_frequency_int;
      end 
      else begin
         trigger_frequency_int <= trigger_frequency_int + 32'd1;
      end
   end

   always @(posedge fe_clk) begin
      if (freq_measure_fe_clk) begin
         fe_frequency_int <= 32'd1;
         fe_frequency <= fe_frequency_int;
      end 
      else begin
         fe_frequency_int <= fe_frequency_int + 32'd1;
      end
   end



   `ifdef ILA_REG
       ila_reg I_reg_ila (
          .clk          (usb_clk),              // input wire clk
          .probe0       (USB_Data),             // input wire [7:0]  probe0  
          .probe1       (USB_Addr),             // input wire [7:0]  probe1 
          .probe2       (USB_nRD),              // input wire [0:0]  probe2 
          .probe3       (USB_nWE),              // input wire [0:0]  probe3 
          .probe4       (USB_nCS),              // input wire [0:0]  probe4 
          .probe5       (isout),                // input wire [0:0]  probe5 
          .probe6       (reg_address[7:0]),     // input wire [7:0]  probe6 
          .probe7       (reg_bytecnt),          // input wire [6:0]  probe7 
          .probe8       (write_data),           // input wire [7:0]  probe8 
          .probe9       (read_data),            // input wire [15:0] probe9 
          .probe10      (reg_read),             // input wire [0:0]  probe10 
          .probe11      (reg_write),            // input wire [0:0]  probe11 
          .probe12      (reg_addrvalid),        // input wire [0:0]  probe12 
          .probe13      (cmdfifo_dout),         // input wire [7:0]  probe13 
          .probe14      (reg_main_selected),    // input wire [0:0]  probe14 
          .probe15      (read_data_main),       // input wire [7:0]  probe15 
          .probe16      (reg_trace_selected),   // input wire [0:0]  probe16 
          .probe17      (read_data_trace),      // input wire [7:0]  probe17 
          .probe18      (read_data_trace_trigger_drp)  // input wire [7:0]  probe18 
       );
   `endif

endmodule
`default_nettype wire