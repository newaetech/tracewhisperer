-- Copyright 1986-2019 Xilinx, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2019.1 (win64) Build 2552052 Fri May 24 14:49:42 MDT 2019
-- Date        : Thu Nov 26 11:15:59 2020
-- Host        : qed running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               w:/hardware/tracewhisperer/vivado/tracewhisperer_swo_only.srcs/sources_1/ip/clk_wiz_swo_only/clk_wiz_swo_only_stub.vhdl
-- Design      : clk_wiz_swo_only
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7s15ftgb196-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity clk_wiz_swo_only is
  Port ( 
    clk_out1 : out STD_LOGIC;
    psclk : in STD_LOGIC;
    psen : in STD_LOGIC;
    psincdec : in STD_LOGIC;
    psdone : out STD_LOGIC;
    reset : in STD_LOGIC;
    locked : out STD_LOGIC;
    clk_in1 : in STD_LOGIC
  );

end clk_wiz_swo_only;

architecture stub of clk_wiz_swo_only is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "clk_out1,psclk,psen,psincdec,psdone,reset,locked,clk_in1";
begin
end;