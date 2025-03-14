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

module tracewhisperer_top #(
  parameter pBYTECNT_SIZE = 7,
  parameter pADDR_WIDTH = 8,
  parameter pBUFFER_SIZE = 64,
  parameter pMATCH_RULES = 8,
  parameter pUSERIO_WIDTH = 4
)(
  // clocks and resets:
  // for simulation only:
  `ifdef __ICARUS__
  input wire  I_trigger_clk,
  input wire  [7:0] I_trace_sdr,
  `endif

  input wire  target_clk,

  // CW trigger:
  output wire trig_out,
  output wire mcx_trig,

  // host USB:
  input  wire          USB_clk,
  inout  wire [7:0]    USB_Data,
  input  wire [pADDR_WIDTH-1:0] USB_Addr,
  input  wire          USB_nRD,
  input  wire          USB_nWE,
  input  wire          USB_nCS,
  output wire          USB_SPARE0,
  input  wire          USB_SPARE1,

  // trace:
  input  wire          TRCENA,
  input  wire          TRACECLOCK,
  input  wire [3:0]    TRACEDATA,

  // target trigger:
  input  wire          target_trig_in,

  // 20-pin user header connector
  inout  wire [pUSERIO_WIDTH-1:0] userio_d,

  // debug:
  output wire         synchronized,

  // leds:
  output wire led1,
  output reg  led2,
  output reg  led3,
  output wire led4
);

  wire arm_usb;
  wire arm_fe;
  wire capturing;
  wire fe_clk;
  wire fpga_reset;
  wire flash_pattern;
  wire led_select;
  wire error_flag;
  wire [3:0] trace_data;
  wire [31:0] buildtime;

  wire [pUSERIO_WIDTH-1:0] userio_pwdriven;
  wire [pUSERIO_WIDTH-1:0] userio_drive_data;
  wire swo;

  wire trigger_clk;
  wire trigger_clk_locked;
  wire trigger_clk_psen;
  wire trigger_clk_psincdec;
  wire trigger_clk_psdone;

  wire [6:0]     trig_drp_addr;
  wire           trig_drp_den;
  wire [15:0]    trig_drp_din;
  wire [15:0]    trig_drp_dout;
  wire           trig_drp_dwe;
  wire           trig_drp_reset;
  
  wire           fifo_full;
  wire           fifo_overflow_blocked;
  wire [17:0]    fifo_in_data;
  wire           fifo_wr;
  wire           fifo_read;
  wire           fifo_flush;
  wire           clear_errors;
  wire [17:0]    fifo_out_data;
  wire [5:0]     fifo_status;
  wire           fifo_empty;
  wire           fifo_error_flag;


  reg [22:0] count_fe_clock = 0;
  reg [22:0] count_trace_clock = 0;
  reg target_trig_in_r;

  always @(posedge fe_clk) count_fe_clock <= count_fe_clock + 1;
  always @(posedge TRACECLOCK) count_trace_clock <= count_trace_clock + 1;

  assign led1 = count_fe_clock[22];     // clock alive; actually routes to PD pin of 20-pin CW connector
  assign led4 = count_trace_clock[22];  // clock alive; actually routes to IO2 pin of 20-pin CW connector

  always @(*) begin
      if (error_flag) begin
          led2 = flash_pattern;
          led3 = flash_pattern;
      end
      else if (led_select) begin
          led2 = count_fe_clock[22];
          led3 = count_trace_clock[22];
      end
      else begin
          led2 = arm_usb;
          led3 = capturing;
      end
  end

  assign mcx_trig = trig_out;

  // Front panel header has different pin mapping in pre-production boards.
  // This affects TRACEDATA too, but we can't mux around the IDDRs so we're
  // stuck (only option is a build-time flag)

  `ifdef REV3
      assign trace_data = {TRACEDATA[3], TRACEDATA[1], TRACEDATA[2], userio_d[3]};
      assign swo = userio_d[1];
  `else
      assign trace_data = TRACEDATA;
      assign swo = userio_d[2];
  `endif

  `ifdef ILA_RAW_TRACE
      ila_raw_trace I_raw_trace_ila (
         .clk          (clk_usb_buf),          // input wire clk
         .probe0       (TRACEDATA),            // input wire [3:0]  probe0  
         .probe1       (userio_d[3]),          // input wire [0:0]  probe1 
         .probe2       (userio_d[2]),          // input wire [0:0]  probe2 
         .probe3       (userio_d[1]),          // input wire [0:0]  probe3 
         .probe4       (TRACECLOCK)            // input wire [0:0]  probe4 
     );
  `endif

  wire clk_usb_buf;

   `ifdef __ICARUS__
      assign clk_usb_buf = USB_clk;
   `else
      IBUFG U_usb_clk_buf (
           .O(clk_usb_buf),
           .I(USB_clk) );
   `endif

   `ifdef __ICARUS__
      assign trigger_clk = I_trigger_clk;
      assign trigger_clk_locked = 1'b1;
      assign trigger_clk_psdone = 1'b1;
   `else
       clk_wiz_0 U_trigger_clock (
         .reset        (fpga_reset),
         .clk_in1      (fe_clk),
         .clk_out1     (trigger_clk),
         // Dynamic phase shift ports
         .psclk        (clk_usb_buf),
         .psen         (trigger_clk_psen),
         .psincdec     (trigger_clk_psincdec),
         .psdone       (trigger_clk_psdone),
         // Status and control signals
         .locked       (trigger_clk_locked),
         // Dynamic reconfiguration ports:
         .daddr        (trig_drp_addr),
         .dclk         (clk_usb_buf),
         .den          (trig_drp_den),
         .din          (trig_drp_din),
         .dout         (trig_drp_dout),
         .drdy         (),
         .dwe          (trig_drp_dwe)
      );
   `endif

   wire isout;
   wire usb_drive_data;
   wire [7:0] cmdfifo_din;
   wire [7:0] cmdfifo_dout_pre;
   //reg  [7:0] cmdfifo_dout_reg;
   wire [7:0] cmdfifo_dout;
   wire [pBYTECNT_SIZE-1:0]  reg_bytecnt;
   wire [7:0]   write_data;
   wire [7:0]   read_data;
   wire         reg_read;
   wire         reg_write;
   wire         reg_addrvalid;


   assign USB_Data = isout ? cmdfifo_dout : 8'bZ;
   assign cmdfifo_din = USB_Data;
   //always @(posedge usb_clk)
   //   cmdfifo_dout_reg <= cmdfifo_dout_pre;
   //assign cmdfifo_dout = O_board_rev[3]? cmdfifo_dout_reg : cmdfifo_dout_pre;
   assign cmdfifo_dout = cmdfifo_dout_pre;


   wire [pADDR_WIDTH-1:0]  reg_address;
   usb_reg_main #(
      .pBYTECNT_SIZE    (pBYTECNT_SIZE)
   ) U_usb_reg_main (
      .cwusb_clk        (clk_usb_buf), 
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


   always @(posedge fe_clk) begin
      target_trig_in_r <= target_trig_in;
   end

   trace_top #(
      .pBYTECNT_SIZE    (pBYTECNT_SIZE),
      .pBUFFER_SIZE     (pBUFFER_SIZE),
      .pMATCH_RULES     (pMATCH_RULES),
      .pUSERIO_WIDTH    (pUSERIO_WIDTH),
      .pMAIN_REG_SELECT (`MAIN_REG_SELECT),
      .pTRACE_REG_SELECT(`TRACE_REG_SELECT)
   ) U_trace_top (
      .trace_clk_in     (TRACECLOCK),
      .fe_clk           (fe_clk),
      .usb_clk          (clk_usb_buf),
      .reset_pin        (1'b0),
      .fpga_reset       (fpga_reset),
      .I_external_arm   (1'b0), // Husky only
      .flash_pattern    (flash_pattern),
      .buildtime        (buildtime),
      .O_trace_en       (), // Husky only
      .O_trace_userio_dir (), // Husky only
      .mmcm_shutdown    (1'b0), // Husky only
      .trace_debug      (), // Husky only
      .capture_start    (), // Husky only
      .capture_done     (), // Husky only

      .trace_data       (trace_data),
      .swo              (swo),
      .O_trace_trig_out (trig_out),
      .m3_trig          (target_trig_in_r),
      .O_soft_trig_passthru (),

      .target_clk       (target_clk),
      .I_fe_clock_count (count_fe_clock),

      .trigger_clk          (trigger_clk),
      .trigger_clk_locked   (trigger_clk_locked),
      .trigger_clk_psen     (trigger_clk_psen    ),
      .trigger_clk_psincdec (trigger_clk_psincdec),
      .trigger_clk_psdone   (trigger_clk_psdone  ),

      .trig_drp_addr    (trig_drp_addr  ),
      .trig_drp_den     (trig_drp_den   ),
      .trig_drp_din     (trig_drp_din   ),
      .trig_drp_dout    (trig_drp_dout  ),
      .trig_drp_dwe     (trig_drp_dwe   ),
      .trig_drp_reset   (trig_drp_reset ),


      `ifdef __ICARUS__
      .I_trace_sdr      (I_trace_sdr),
      `endif
                                  
      .USB_nCS          (USB_nCS  ),
      .O_data_available (USB_SPARE0 ),
      .I_fast_fifo_rdn  (USB_SPARE1 ),

      .usb_drive_data   (usb_drive_data),
      .reg_address      (reg_address[7:0]), 
      .reg_bytecnt      (reg_bytecnt), 
      .write_data       (write_data), 
      .read_data        (read_data),
      .reg_read         (reg_read), 
      .reg_write        (reg_write), 
      .reg_addrvalid    (reg_addrvalid),

      .O_led_select     (led_select),
      .O_error_flag     (error_flag),

      .userio_d         (userio_d),
      .O_userio_pwdriven (userio_pwdriven),
      .O_userio_drive_data (userio_drive_data),

      .arm_usb          (arm_usb),
      .arm_fe           (arm_fe),
      .capturing        (capturing),

      .fifo_full        (fifo_full),
      .fifo_overflow_blocked (fifo_overflow_blocked),
      .fifo_in_data     (fifo_in_data),
      .fifo_wr          (fifo_wr),
                               
      .fifo_read        (fifo_read),
      .fifo_flush       (fifo_flush),
      .clear_errors     (clear_errors),
                               
      .fifo_out_data    (fifo_out_data),
      .fifo_status      (fifo_status),
      .fifo_empty       (fifo_empty),
      .fifo_error_flag  (fifo_error_flag),

      .synchronized     (synchronized)      

   );

   userio #(
      .pWIDTH                   (pUSERIO_WIDTH)
   ) U_userio (
      .usb_clk                  (1'b0),
      .userio_d                 (userio_d),
      .userio_clk               (1'b0),
      .I_userio_pwdriven        (userio_pwdriven),
      .I_userio_drive_data      (userio_drive_data)
   );

   `ifndef NOFIFO // for clean compilation
   fifo U_fifo (
      .reset_i                  (fpga_reset),
      .cwusb_clk                (clk_usb_buf),
      .fe_clk                   (fe_clk),

      .O_fifo_full              (fifo_full),
      .O_fifo_overflow_blocked  (fifo_overflow_blocked),
      .I_data                   (fifo_in_data),
      .I_wr                     (fifo_wr),

      .I_fifo_read              (fifo_read),
      .I_fifo_flush             (fifo_flush),
      .I_clear_read_flags       (arm_usb),
      .I_clear_write_flags      (arm_fe),
      .I_clear_errors           (clear_errors),

      .O_data                   (fifo_out_data),
      .O_fifo_status            (fifo_status),
      .O_fifo_empty             (fifo_empty),
      .O_error_flag             (fifo_error_flag),

      .I_custom_fifo_stat_flag  (synchronized)      
   );
   `endif


   `ifndef __ICARUS__
      USR_ACCESSE2 U_buildtime (
         .CFGCLK(),
         .DATA(buildtime),
         .DATAVALID()
      );
   `else
      assign buildtime = 0;
   `endif


endmodule
`default_nettype wire
