-- =============================================================================
-- tc_frame_pkg.vhd
-- Ground Segment - Shared Package
--
-- Provides default header field values and helper functions for building
-- TC Transfer Frame Primary Headers per CCSDS 232.0-B-4.
--
-- Also declares constants used by Frame_Sync_and_Encoding to delimit
-- the ASM (Attached Sync Marker) sequence.
--
-- Dependencies:
--   work.ccsds_types_pkg (src/common/)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.ccsds_types_pkg.all;

package tc_frame_pkg is

    -- =========================================================================
    -- SECTION 1: DEFAULT PRIMARY HEADER VALUES
    -- =========================================================================

    constant DEFAULT_TFVN : std_logic_vector(1 downto 0) := "00";
    constant DEFAULT_SCID : std_logic_vector(9 downto 0) := "0000000001";
    constant DEFAULT_VCID : std_logic_vector(5 downto 0) := "000000";

    -- =========================================================================
    -- SECTION 2: FRAME SYNCHRONIZATION CONSTANTS
    -- CCSDS 231.0-B-4, Section 2.1.3.
    -- Full 4-byte sequence: 0x55 (preamble) + 0xFA 0xF3 0x20 (CCSDS ASM).
    -- To use the bare 3-byte CCSDS ASM, set ASM_BYTES := 3 and remove
    -- the 0x55 entry from ASM_PATTERN.
    -- =========================================================================

    constant ASM_BYTES : integer := 4;

    type t_asm is array (0 to ASM_BYTES - 1) of t_byte;
    constant ASM_PATTERN : t_asm := (
        0 => x"55",
        1 => x"FA",
        2 => x"F3",
        3 => x"20"
    );

    -- =========================================================================
    -- SECTION 3: HELPER FUNCTIONS
    -- =========================================================================

    function make_header(
        bypass    : std_logic;
        cc_flag   : std_logic;
        scid      : std_logic_vector(SCID_WIDTH      - 1 downto 0);
        vcid      : std_logic_vector(VCID_WIDTH      - 1 downto 0);
        frame_len : std_logic_vector(FRAME_LEN_WIDTH - 1 downto 0);
        fsn       : std_logic_vector(FSN_WIDTH       - 1 downto 0)
    ) return t_tc_header;

end package tc_frame_pkg;

package body tc_frame_pkg is

    function make_header(
        bypass    : std_logic;
        cc_flag   : std_logic;
        scid      : std_logic_vector(SCID_WIDTH      - 1 downto 0);
        vcid      : std_logic_vector(VCID_WIDTH      - 1 downto 0);
        frame_len : std_logic_vector(FRAME_LEN_WIDTH - 1 downto 0);
        fsn       : std_logic_vector(FSN_WIDTH       - 1 downto 0)
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