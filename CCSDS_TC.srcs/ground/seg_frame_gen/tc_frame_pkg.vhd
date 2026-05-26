-- src/ground/seg_frame_gen/tc_frame_pkg.vhd
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.ccsds_types_pkg.all;   -- pulls in t_tc_header, t_frame, t_data_buf, etc.

package tc_frame_pkg is

    -- Default header field values for ground-originated TCs
    constant DEFAULT_TFVN   : std_logic_vector(1 downto 0) := "00";
    constant DEFAULT_SCID   : std_logic_vector(9 downto 0) := "0000000001";  -- mission-specific
    constant DEFAULT_VCID   : std_logic_vector(5 downto 0) := "000000";

    -- Helper: build a complete t_tc_header from fields
    function make_header(
        bypass    : std_logic;
        cc_flag   : std_logic;
        scid      : std_logic_vector(SCID_WIDTH - 1 downto 0);
        vcid      : std_logic_vector(VCID_WIDTH - 1 downto 0);
        frame_len : std_logic_vector(FRAME_LEN_WIDTH - 1 downto 0);
        fsn       : std_logic_vector(FSN_WIDTH - 1 downto 0)
    ) return t_tc_header;

end package tc_frame_pkg;

package body tc_frame_pkg is

    function make_header(
        bypass    : std_logic;
        cc_flag   : std_logic;
        scid      : std_logic_vector(SCID_WIDTH - 1 downto 0);
        vcid      : std_logic_vector(VCID_WIDTH - 1 downto 0);
        frame_len : std_logic_vector(FRAME_LEN_WIDTH - 1 downto 0);
        fsn       : std_logic_vector(FSN_WIDTH - 1 downto 0)
    ) return t_tc_header is
        variable hdr : t_tc_header;
    begin
        hdr.tfvn          := DEFAULT_TFVN;
        hdr.bypass        := bypass;
        hdr.cc_flag       := cc_flag;
        hdr.spacecraft_id := scid;
        hdr.vcid          := vcid;
        hdr.frame_length  := frame_len;
        hdr.frame_seq_nr  := fsn;
        return hdr;
    end function make_header;

end package body tc_frame_pkg;