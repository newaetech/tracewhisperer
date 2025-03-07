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
  parameter pBUFFER_SIZE = 64,
  parameter pMATCH_RULES = 8,
  parameter pTRIGGER_DELAY_WIDTH = 20,
  parameter pTRIGGER_WIDTH_WIDTH = 17,
  parameter pNUM_TRIGGER_PULSES = 8,
  parameter pNUM_TRIGGER_WIDTH = 4,
  parameter pCAPTURE_LEN_WIDTH = 32,
  parameter pTIMESTAMP_FULL_WIDTH = 16,
  parameter pTIMESTAMP_SHORT_WIDTH = 8,
  parameter pUSERIO_WIDTH = 4,
  parameter pMAIN_REG_SELECT  = `MAIN_REG_SELECT,
  parameter pTRACE_REG_SELECT = `TRACE_REG_SELECT,
  parameter pREGISTERED_READ = 1

)(
  input  wire                           trace_clk_in,
  output wire                           fe_clk,
  input  wire                           usb_clk,
  input  wire                           reset_pin,
  output wire                           fpga_reset,
  input  wire                           I_external_arm,         // usb_clk clock domain
  output reg                            flash_pattern,
  input  wire [31:0]                    buildtime,
  output wire                           O_trace_en,
  output wire                           O_trace_capture_on,
  output wire [7:0]                     O_trace_userio_dir,
  input  wire                           mmcm_shutdown,

  input wire                            target_clk,
  input wire  [22:0]                    I_fe_clock_count,

  input wire                            trigger_clk,
  input wire                            trigger_clk_locked,
  output wire                           trigger_clk_psen,
  output wire                           trigger_clk_psincdec,
  input  wire                           trigger_clk_psdone,

  `ifdef __ICARUS__
  // for simulation only:
  input wire [7:0]                      I_trace_sdr,
  `endif

  // trace:
  input  wire [3:0]                     trace_data,
  input  wire                           swo,
  output wire                           O_trace_trig_out,
  input  wire                           m3_trig,
  output wire                           O_soft_trig_passthru,

  // USB:
  input  wire                           USB_nCS,
  output wire                           O_data_available,
  input  wire                           I_fast_fifo_rdn,
  output wire                           usb_drive_data,

  input  wire [pBYTECNT_SIZE-1:0]       reg_bytecnt,
  input  wire [7:0]                     write_data,
  output wire [7:0]                     read_data,
  input  wire                           reg_read,
  input  wire                           reg_write,
  input  wire                           reg_addrvalid,
  input  wire [7:0]                     reg_address,

  output wire                           O_led_select,
  output wire                           O_error_flag,

  output wire [6:0]                     trig_drp_addr,
  output wire                           trig_drp_den,
  output wire [15:0]                    trig_drp_din,
  input  wire [15:0]                    trig_drp_dout,
  output wire                           trig_drp_dwe,
  output wire                           trig_drp_reset,


  // USERIO pins: (TraceWhisperer/Husky only, unused for CW305)
  input  wire [pUSERIO_WIDTH-1:0]       userio_d,
  output wire [pUSERIO_WIDTH-1:0]       O_userio_pwdriven,
  output wire [pUSERIO_WIDTH-1:0]       O_userio_drive_data,

  // Status LEDs:
  output wire                           arm_usb,
  output wire                           arm_fe,
  output wire                           capturing,

  output wire                           capture_start,
  output wire                           capture_done,

  // FIFO interface:
  input  wire                           fifo_full,
  input  wire                           fifo_overflow_blocked,
  output wire [17:0]                    fifo_in_data,
  output wire                           fifo_wr,
  output wire                           fifo_read,
  output wire                           fifo_flush,
  output wire                           clear_errors,
  input  wire [17:0]                    fifo_out_data,
  input  wire [5:0]                     fifo_status,
  input  wire                           fifo_empty,
  input  wire                           fifo_error_flag,
  output wire                           synchronized,

  // Debug:
  output wire [8:0]                     trace_debug,
  output wire [7:0]                     trace_data_sdr
);

   parameter pALL_TRIGGER_DELAY_WIDTHS = 24*pNUM_TRIGGER_PULSES;
   parameter pALL_TRIGGER_WIDTH_WIDTHS = 24*pNUM_TRIGGER_PULSES;
   parameter pCAPTURE_DELAY_WIDTH = pTRIGGER_DELAY_WIDTH - 2;

   wire [1:0]   fe_clk_sel;
   wire         trace_clock_sel;
   wire         trace_clk_shifted;

   wire [6:0]   traceclk_drp_addr;
   wire         traceclk_drp_den;
   wire [15:0]  traceclk_drp_din;
   wire [15:0]  traceclk_drp_dout;
   wire         traceclk_drp_dwe;
   wire         traceclk_drp_reset;

   wire         phase_load;
   wire [15:0]  phase_requested;
   wire         phase_done;
   wire         mmcm_PSEN;
   wire         mmcm_PSINCDEC;
   wire         mmcm_PSDONE;

   wire         phase_locked;
   wire         traceclk_shift_en;
   wire         trace_clk_selected;

   wire reset;

`ifndef __ICARUS__
   wire mmcm_clkfb;
   MMCME2_ADV #(
      .BANDWIDTH                    ("OPTIMIZED"), // Jitter programming (OPTIMIZED, HIGH, LOW)
      .CLKFBOUT_MULT_F              (32.0), // Multiply value for all CLKOUT (2.000-64.000); default values allow for clock of 9 - 18 MHz
      .CLKOUT0_DIVIDE_F             (32.0),
      .CLKFBOUT_PHASE               (0.0), // Phase offset in degrees of CLKFB (-360.000-360.000).
      .CLKIN1_PERIOD                (100.0),
      .CLKOUT0_DUTY_CYCLE           (0.5),
      .CLKOUT0_PHASE                (0.0),  // Phase offset for CLKOUT outputs (-360.000-360.000).
      .CLKOUT4_CASCADE              ("FALSE"), // Cascade CLKOUT4 counter with CLKOUT6 (FALSE, TRUE)
      .COMPENSATION                 ("INTERNAL"), // ZHOLD, BUF_IN, EXTERNAL, INTERNAL
      .DIVCLK_DIVIDE                (1), // Master division value (1-106)
      .STARTUP_WAIT                 ("FALSE"), // Delays DONE until MMCM is locked (FALSE, TRUE)
      .CLKFBOUT_USE_FINE_PS         ("FALSE"),
      .CLKOUT0_USE_FINE_PS          ("TRUE")
   ) U_trace_clock_mmcm (
      // Clock Outputs:
      .CLKOUT0                      (trace_clk_shifted), 
      .CLKOUT0B                     (),
      .CLKOUT1                      (),
      .CLKOUT1B                     (),
      .CLKOUT2                      (),
      .CLKOUT2B                     (),
      .CLKOUT3                      (),
      .CLKOUT3B                     (),
      .CLKOUT4                      (),
      .CLKOUT5                      (),
      .CLKOUT6                      (),
      // Feedback Clocks:
      .CLKFBOUT                     (mmcm_clkfb),
      .CLKFBOUTB                    (),
      // Status Ports: 1-bit (each) output: MMCM status ports
      .CLKFBSTOPPED                 (),
      .CLKINSTOPPED                 (),
      .LOCKED                       (phase_locked),
      // Clock Inputs:
      .CLKIN1                       (trace_clk_in),
      .CLKIN2                       (1'b0),
      // Control Ports: 1-bit (each) input: MMCM control ports
      .CLKINSEL                     (1'b1),
      .PWRDWN                       (~traceclk_shift_en || mmcm_shutdown),
      .RST                          (traceclk_drp_reset),
      // DRP Ports:
      .DADDR                        (traceclk_drp_addr),
      .DCLK                         (usb_clk),
      .DEN                          (traceclk_drp_den),
      .DI                           (traceclk_drp_din),
      .DWE                          (traceclk_drp_dwe),
      .DO                           (traceclk_drp_dout),
      .DRDY                         (),
      // Dynamic Phase Shift Ports:
      .PSCLK                        (usb_clk),
      .PSEN                         (mmcm_PSEN),
      .PSINCDEC                     (mmcm_PSINCDEC),
      .PSDONE                       (mmcm_PSDONE),
      // Feedback Clocks
      .CLKFBIN                      (mmcm_clkfb) // 1-bit input: Feedback clock
   );

   BUFGMUX #(
        .CLK_SEL_TYPE("ASYNC")
   ) U_traceclk_sel (
       .O      (trace_clk_selected),
       .I0     (trace_clk_in),
       .I1     (trace_clk_shifted),
       .S      (traceclk_shift_en)
   );

`else
   assign #1 trace_clk_shifted = trace_clk_in;
   assign trace_clk_selected = traceclk_shift_en? trace_clk_shifted : trace_clk_in;

`endif

   reg_mmcm_drp #(
      .pBYTECNT_SIZE    (pBYTECNT_SIZE),
      .pDRP_ADDR        (`REG_TRACECLK_DRP_ADDR),
      .pDRP_DATA        (`REG_TRACECLK_DRP_DATA),
      .pDRP_RESET       (`REG_TRACECLK_DRP_RESET)
   ) U_trace_clock_drp (
      .reset_i          (reset),
      .clk_usb          (usb_clk),
      .selected         (reg_trace_selected),
      .reg_address      ({2'b0, reg_address[5:0]}), 
      .reg_bytecnt      (reg_bytecnt), 
      .reg_datao        (read_data_traceclk_drp), 
      .reg_datai        (write_data), 
      .reg_read         (reg_read), 
      .reg_write        (reg_write), 
      .drp_addr         (traceclk_drp_addr ),
      .drp_den          (traceclk_drp_den  ),
      .drp_din          (traceclk_drp_din  ),
      .drp_dout         (traceclk_drp_dout ),
      .drp_dwe          (traceclk_drp_dwe  ),
      .drp_reset        (traceclk_drp_reset)
   ); 

   mmcm_phaseshift_interface U_trace_clock_shift (
       .clk_usb         (usb_clk),
       .reset           (traceclk_drp_reset),
       .I_step_index    (phase_requested),
       .I_load          (phase_load),
       .O_done          (phase_done),
       .O_psen          (mmcm_PSEN),
       .O_psincdec      (mmcm_PSINCDEC),
       .I_psdone        (mmcm_PSDONE)
   );


   wire [7:0] trace_data_iddr;

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
               //.DDR_CLK_EDGE     ("SAME_EDGE_PIPELINED"),
               .INIT_Q1          (0),
               .INIT_Q2          (0),
               .SRTYPE           ("SYNC")
            ) U_trace_data_iddr (
               .Q1               (trace_data_iddr[i]),
               .Q2               (trace_data_iddr[i+4]),
               //.Q1               (trace_data_iddr[i+4]),
               //.Q2               (trace_data_iddr[i]),
               .D                (trace_data[i]),
               .CE               (trace_clock_sel),
               .C                (fe_clk),
               .S                (1'b0),
               .R                (1'b0)
            );
         end
      endgenerate

   `endif

   assign trace_data_sdr = trace_clock_sel? trace_data_iddr : {4'b0, trace_data};

   assign fpga_reset = reset;

   assign trace_debug = { 1'b0,
                          trace_data,           // D6:D3
                          fe_clk,               // D2
                          trace_clk_in,         // D1
                          target_clk            // D0
                        };


   `ifdef CW305
      assign fe_clk = target_clk;
      assign trace_clock_sel = 1'b0;

   `else // PhyWhisperer platform
      assign trace_clock_sel = fe_clk_sel == 2'b01;

      `ifndef __ICARUS__
         wire fe_clk_pre;
         BUFGMUX U_fe_clock_mux1 (
            .I0            (target_clk),
            .I1            (trace_clk_selected),
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
                         fe_clk_sel[0]?  trace_clk_selected : 
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


   wire capture_while_trig;
   wire [15:0] max_timestamp;

   wire reg_main_selected;
   wire reg_trace_selected;

   wire trigger_enable;
   wire soft_trig_enable;
   wire [pNUM_TRIGGER_WIDTH-1:0] num_triggers;
   wire [pNUM_TRIGGER_WIDTH-1:0] triggers_generated;
   wire [pALL_TRIGGER_DELAY_WIDTHS-1:0] trigger_delay;
   wire [pALL_TRIGGER_WIDTH_WIDTHS-1:0] trigger_width;
   wire trigger_match;
   wire triggering;

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

   wire [15:0] swo_bitrate_div;
   wire swo_enable;
   wire swo_data_ready;
   wire [7:0] swo_data_byte;
   wire swo_cdc_fifo_overflow;
   reg swo_ack;
   wire uart_reset;
   wire [2:0] uart_rx_state;
   wire [3:0] uart_data_bits;
   wire [1:0] uart_stop_bits;
   wire reg_capture_off;
   wire reset_sync_from_reg;
   wire timestamps_disable;

   reg [25:0] timer_heartbeat;
   reg freq_measure;
   reg timer_heartbeat22r;
   wire freq_measure_trigger_clk;
   reg [31:0] trigger_frequency_int;
   reg [31:0] trigger_frequency;
   wire freq_measure_fe_clk;
   reg [31:0] fe_frequency_int;
   reg [31:0] fe_frequency;
   reg capturing_r;

   wire [7:0]   read_data_trace;
   wire [7:0]   read_data_trace_trigger_drp;
   wire [7:0]   read_data_traceclk_drp;
   wire [7:0]   read_data_main;
   wire [pBUFFER_SIZE-1:0] revbuffer;

   assign O_error_flag = swo_cdc_fifo_overflow || fifo_error_flag;

   assign O_trace_capture_on = ~reg_capture_off & O_trace_en;

   reg_trace #(
      .pBYTECNT_SIZE            (pBYTECNT_SIZE),
      .pBUFFER_SIZE             (pBUFFER_SIZE),
      .pMATCH_RULES             (pMATCH_RULES),
      .pSELECT                  (pTRACE_REG_SELECT),
      .pREGISTERED_READ         (pREGISTERED_READ)
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
      .O_trace_en               (O_trace_en),
      .O_trace_userio_dir       (O_trace_userio_dir),

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
      .I_revbuffer              (revbuffer       ),

      .O_swo_enable             (swo_enable      ),
      .O_swo_bitrate_div        (swo_bitrate_div ),
      .O_uart_stop_bits         (uart_stop_bits  ),
      .O_uart_data_bits         (uart_data_bits  ),

      .O_reset_sync             (reset_sync_from_reg),

      .uart_reset               (uart_reset),
      .uart_state               (uart_rx_state),

      .O_phase_load             (phase_load),
      .O_phase_requested        (phase_requested),
      .I_phase_done             (phase_done),
      .I_phase_locked           (phase_locked),
      .O_traceclk_shift_en      (traceclk_shift_en),

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
      .pBUFFER_SIZE             (pBUFFER_SIZE),
      .pNUM_TRIGGER_PULSES      (pNUM_TRIGGER_PULSES),
      .pNUM_TRIGGER_WIDTH       (pNUM_TRIGGER_WIDTH),
      .pCAPTURE_LEN_WIDTH       (pCAPTURE_LEN_WIDTH),
      .pQUICK_START_DEFAULT     (1),
      .pUSERIO_WIDTH            (pUSERIO_WIDTH),
      .pSELECT                  (pMAIN_REG_SELECT),
      .pREGISTERED_READ         (pREGISTERED_READ)
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
      .I_external_arm   (I_external_arm),
      .O_arm_usb        (arm_usb),
      .O_arm_fe         (arm_fe),
      .O_capture_off    (reg_capture_off),
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
      .I_triggers_generated (triggers_generated),

      // Trigger clock phase shift:
      .O_psincdec       (trigger_clk_psincdec),
      .O_psen           (trigger_clk_psen),
      .I_psdone         (trigger_clk_psdone),

      .selected         (reg_main_selected),
      .buildtime        (buildtime)
   );

   assign read_data = reg_main_selected? read_data_main :
                      reg_trace_selected?  read_data_trace | read_data_trace_trigger_drp | read_data_traceclk_drp : 8'h00;


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
      .I_arm_fe                 (arm_fe),
      .I_capture_len            (capture_len),
      .I_count_writes           (count_writes),
      .I_capture_off            (reg_capture_off),
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
      .I_reset_sync_reg         (reset_sync_from_reg),
      .I_capture_raw            (capture_raw),
      .I_record_syncs           (record_syncs),
      .I_pattern_enable         (pattern_enable  ),
      .I_pattern_trig_enable    (pattern_trig_enable),
      .I_soft_trig_enable       (soft_trig_enable),
      .I_arm_fe                 (arm_fe),
      .I_arm_usb                (arm_usb),
      .I_swo_enable             (swo_enable),
      .I_capture_now            (capture_now),
      .revbuffer                (revbuffer),

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
      .I_triggering             (triggering),
      .m3_trig                  (m3_trig)

   /* PATTERN MATCHER CONNECTIONS
      .O_pm_data                (),
      .O_pm_data_valid          () */

   );


   `ifndef CW305
      uart_core U_uart_rx (
         //.clk                      (trace_clk),
         .clk                      (trigger_clk),
         .reset_n                  (~(reset || uart_reset)),
         // Configuration inputs
         .bit_rate                 (swo_bitrate_div),
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
          //.clk          (trigger_clk),          // input wire clk
          .clk          (usb_clk),          // input wire clk
          .probe0       (swo),                  // input wire [0:0]  probe0  
          .probe1       (swo_bitrate_div[7:0]), // input wire [7:0]  probe1 
          .probe2       (swo_data_ready),       // input wire [0:0]  probe2 
          .probe3       (swo_ack),              // input wire [0:0]  probe3 
          .probe4       (uart_rx_state),        // input wire [2:0]  probe4 
          .probe5       (swo_data_byte),        // input wire [7:0]  probe5 
          .probe6       (m3_trig)               // input wire [0:0]  probe6 
       );
   `endif


   `ifdef PW_TRIGGER
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
          .I_capture_delay  (18'b0),
          .I_trigger_delay  (trigger_delay),
          .I_trigger_width  (trigger_width),
          .I_trigger_enable (trigger_enable),
          .I_num_triggers   (num_triggers),
          .O_capture_enable_pulse (capture_enable_pulse),
          .I_match          (trigger_match),
          .I_capturing      (capturing),
          .O_capture_enable (capture_enable)
       );

   `else
       simple_trigger #(
          .pNUM_TRIGGER_WIDTH (pNUM_TRIGGER_WIDTH)
       ) U_simple_trigger (
          .reset_i          (reset),
          .fe_clk           (fe_clk),
          .usb_clk          (usb_clk),
          .I_arm            (arm_fe),
          .O_trigger        (O_trace_trig_out),
          .O_capture_enable_pulse (capture_enable_pulse),
          .I_trigger_enable (trigger_enable),
          .I_capture_off    (reg_capture_off),
          .I_num_triggers   (num_triggers),
          .O_triggers_generated (triggers_generated),
          .I_match          (trigger_match),
          .O_triggering     (triggering),
          .I_capturing      (capturing),
          .O_capture_enable (capture_enable)
       );
   `endif


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

   always @(posedge fe_clk) begin
       if (reset)
           capturing_r <= 1'b0;
       else
           capturing_r <= capturing;
   end

   assign capture_start = capturing && ~capturing_r;
   assign capture_done = ~capturing && capturing_r;


   `ifdef ILA_REG
       // TODO- update
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
