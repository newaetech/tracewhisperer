/* 
ChipWhisperer Artix Target - Example of connections between example registers
and rest of system.

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

`timescale 1ns / 1ns
`default_nettype none 

`include "defines.v"

module tb();
    parameter pADDR_WIDTH = 21;
    parameter pBYTECNT_SIZE = 7;
    parameter pUSB_CLOCK_PERIOD = 10;
    parameter pPLL_CLOCK_PERIOD = 6;
    parameter pSEED = 1;
    parameter pTIMEOUT = 200000;
    parameter pVERBOSE = 1;

    reg usb_clk;
    wire [7:0] usb_data;
    reg [7:0] usb_wdata;
    reg [pADDR_WIDTH-1:0] usb_addr;
    reg usb_rdn;
    reg usb_wrn;
    reg usb_cen;

    reg j16_sel;
    reg k16_sel;
    reg k15_sel;
    reg l14_sel;
    reg pushbutton;
    reg pll_clk1;
    reg tio_clkin;

    wire led1;
    wire led2;
    wire led3;

    wire tio_trigger;
    wire tio_clkout;


    int seed;
    int errors;
    int i;
    
    reg [31:0] read_data;
    reg [31:0] write_data;

   initial begin
      seed = pSEED;
      errors = 0;
      $display("Running with pSEED=%0d", pSEED);
      //$urandom(seed);
      $dumpfile("results/tb.fst");
      $dumpvars(0, tb);
      usb_clk = 1'b1;
      pll_clk1 = 1'b1;

      usb_wdata = 0;
      usb_addr = 0;
      usb_rdn = 1;
      usb_wrn = 1;
      usb_cen = 1;

      j16_sel = 0;
      k16_sel = 0;
      k15_sel = 0;
      l14_sel = 0;
      pushbutton = 1;
      pll_clk1 = 0;
      tio_clkin = 0;

      // pushbutton = ~rst
      #(pUSB_CLOCK_PERIOD*2) pushbutton = 0;
      #(pUSB_CLOCK_PERIOD*2) pushbutton = 1;
      #(pUSB_CLOCK_PERIOD*10);


      $display("Test read and write:");
      for (i = 0; i < 10; i += 1) begin
         //write_data = 'h66;
         write_data = 32'h12345678 + i;
         write_word('h03, write_data);
         #(pUSB_CLOCK_PERIOD*4);
         read_word('h03, read_data);
         #(pUSB_CLOCK_PERIOD*4);
         if (read_data !== write_data) begin
            $display("Error (iteration=%3d)! wrote %h, read %h", i, write_data, read_data);
            errors += 1;
         end
      end

      #(pUSB_CLOCK_PERIOD*150);
      $display("done!");
      if (errors)
         $display("SIMULATION FAILED (%0d errors).", errors);
      else
         $display("Simulation passed");
      $finish;
   end


   // timeout thread:
   initial begin
      #(pUSB_CLOCK_PERIOD*pTIMEOUT);
      errors += 1;
      $display("ERROR: global timeout");
      $display("SIMULATION FAILED (%0d errors).", errors);
      $finish;
   end


   assign usb_data = usb_wrn? 8'bz : usb_wdata;


   task write_byte;
      input [pADDR_WIDTH-pBYTECNT_SIZE-1:0] address;
      input [pBYTECNT_SIZE-1:0] subbyte;
      input [7:0] data;
      @(posedge usb_clk);
      usb_addr = {address, subbyte};
      usb_wdata = data;
      usb_wrn = 0;
      @(posedge usb_clk);
      usb_cen = 0;
      @(posedge usb_clk);
      usb_cen = 1;
      @(posedge usb_clk);
      usb_wrn = 1;
   endtask


   task read_byte;
      input [pADDR_WIDTH-pBYTECNT_SIZE-1:0] address;
      input [pBYTECNT_SIZE-1:0] subbyte;
      output [7:0] data;
      @(posedge usb_clk);
      usb_addr = {address, subbyte};
      @(posedge usb_clk);
      usb_rdn = 0;
      usb_cen = 0;
      @(posedge usb_clk);
      usb_cen = 1;
      #1 data = usb_data;
      repeat(2) @(posedge usb_clk);
      usb_rdn = 1;
   endtask


   task write_word;
      input [pADDR_WIDTH-pBYTECNT_SIZE-1:0] address;
      input [31:0] data;
      int subbyte;
      for (subbyte = 0; subbyte < 4; subbyte = subbyte + 1)
         write_byte(address, subbyte, data[subbyte*8 +: 8]);
      if (pVERBOSE)
         $display("Write %0h", data);
   endtask


   task read_word;
      input [pADDR_WIDTH-pBYTECNT_SIZE-1:0] address;
      output [31:0] data;
      int subbyte;
      for (subbyte = 0; subbyte < 4; subbyte = subbyte + 1)
         read_byte(address, subbyte, data[subbyte*8 +: 8]);
      if (pVERBOSE)
         $display("Read %0h", data);
   endtask


   always #(pUSB_CLOCK_PERIOD/2) usb_clk = !usb_clk;
   always #(pPLL_CLOCK_PERIOD/2) pll_clk1 = !pll_clk1;


   CW305_designstart_top #(
       .pADDR_WIDTH        (pADDR_WIDTH),
       .pBYTECNT_SIZE      (pBYTECNT_SIZE)
   ) U_dut (
       // USB Interface
       .USB_clk            (usb_clk    ),
       .USB_Data           (usb_data   ),
       .USB_Addr           (usb_addr   ),
       .USB_nRD            (usb_rdn    ),
       .USB_nWE            (usb_wrn    ),
       .USB_nCS            (usb_cen    ),

       // Buttons/LEDs on Board
       .j16_sel            (j16_sel   ),
       .k16_sel            (k16_sel   ),
       .k15_sel            (k15_sel   ),
       .l14_sel            (l14_sel   ),
       .resetn             (pushbutton),
       .led1               (led1      ),
       .led2               (led2      ),
       .led3               (led3      ),

       // PLL
       .pll_clk1           (pll_clk1),

       // 20-Pin Connector
       //.tio_trigger        (tio_trigger),
       //.tio_clkout         (tio_clkout ),
       .tio_clkin          (tio_clkin  ),

       // unused here:
       .swclk              (1'b0),
       .TDI                (1'b0),
       .nTRST              (1'b0),
       .uart_rxd           (1'b0)
   );


endmodule

`default_nettype wire
