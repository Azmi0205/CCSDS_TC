----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 19.05.2026 12:10:41
-- Design Name: 
-- Module Name: ccsds_types_pkg - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Revision 0.02 - Added TC Segment Header support (sequence flags, MAP ID)
-- Additional Comments:
-- 
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package ccsds_types_pkg is

    -- =========================================================================
    -- SECTION 1: PRIMARY HEADER FIELD WIDTHS (in bits)
    -- All values are FIXED by CCSDS 232.0-B-4, Section 4.1.
    -- =========================================================================

    -- Transfer Frame Version Number.
    -- Always "00" for TC frames as defined in CCSDS 232.0-B-4.
    constant TFVN_WIDTH       : integer := 2;

    -- Bypass Flag (1 bit).
    -- When '1', the frame bypasses the sequence check on the space side.
    -- When '0', normal sequence-checked mode (Type-A frame).
    constant BYPASS_WIDTH     : integer := 1;

    -- Control Command Flag (1 bit).
    -- When '0', the frame carries data (TC Segment in Data Field).
    -- When '1', the frame carries a control command (no data field follows).
    constant CC_FLAG_WIDTH    : integer := 1;

    -- Reserved bits in the first header word.
    -- Must always be set to "00". Reserved for future CCSDS use.
    constant RESERVED_WIDTH   : integer := 2;

    -- Spacecraft Identifier width (10 bits).
    -- Uniquely identifies the target satellite. Assigned by mission operations.
    -- Range: 0 to 1023. Set at mission level via GS_Configuration_Reg.
    constant SCID_WIDTH       : integer := 10;

    -- Virtual Channel Identifier width (6 bits).
    -- Identifies which virtual channel this frame belongs to.
    -- Range: 0 to 63. Allows multiplexing of multiple data streams.
    -- Fixed field width by protocol, but the VALUE is mission-configurable.
    constant VCID_WIDTH       : integer := 6;

    -- Frame Length field width (10 bits).
    -- Encodes the total byte length of the frame MINUS ONE.
    -- Example: a 71-byte frame has Frame Length field value = 70.
    constant FRAME_LEN_WIDTH  : integer := 10;

    -- Frame Sequence Number width (8 bits).
    -- Auto-incrementing counter (0 to 255, wraps around).
    -- Used by the space-side receiver to detect lost or out-of-order frames.
    constant FSN_WIDTH        : integer := 8;

    -- =========================================================================
    -- SECTION 1B: TC SEGMENT HEADER FIELD WIDTHS (in bits)
    -- Defined in CCSDS 232.0-B-4, Section 4.2 (TC Data Field).
    -- The segment header is the FIRST byte of the TC Data Field.
    -- It is present when CC_FLAG = '0' (data frame).
    -- =========================================================================

    -- Sequence Flags field width (2 bits).
    -- Indicates the segmentation status of the data carried in this frame.
    -- Values are defined as constants SEG_FLAG_* below.
    -- FIXED by protocol - do NOT change.
    constant SEG_FLAG_WIDTH   : integer := 2;

    -- Multiplexer Access Point Identifier width (6 bits).
    -- Identifies the logical data channel (MAP) within a virtual channel.
    -- Range: 0 to 63. Allows multiplexing of multiple packet streams on one VC.
    -- FIXED by protocol - do NOT change.
    constant MAP_ID_WIDTH     : integer := 6;

    -- Total segment header size in bytes.
    -- SEG_FLAG_WIDTH + MAP_ID_WIDTH = 8 bits = 1 byte. FIXED by protocol.
    constant TC_SEG_HDR_BYTES : integer := 1;

    -- =========================================================================
    -- SECTION 2: FRAME STRUCTURE SIZES (in bytes)
    -- Derived from the field widths above. Fixed by CCSDS 232.0-B-4.
    -- =========================================================================

    -- Size of the TC Transfer Frame Primary Header.
    -- Sum of all header fields: (2+1+1+2+10+6+10+8) = 40 bits = 5 bytes.
    constant TC_HEADER_BYTES  : integer := 5;

    -- Size of the Frame Error Control Field (FECF).
    -- Contains a 16-bit CRC checksum appended at the end of every frame.
    -- Optional by protocol, but REQUIRED in this implementation for reliability.
    -- 2 Fixed by protocol if used - do NOT change.
    -- Set to 0: CRC check disabled in this implementation
    constant TC_FECF_BYTES    : integer := 0;

    -- =========================================================================
    -- SECTION 3: FRAME SIZE LIMITS
    -- Maximum values are FIXED by CCSDS 232.0-B-4, Section 4.1.3.
    -- =========================================================================

    -- Maximum total TC Transfer Frame size in bytes.
    -- Hard upper limit defined by CCSDS 232.0-B-4.
    -- A frame may never exceed 1024 bytes total (header + data + FECF).
    constant TC_MAX_FRAME_BYTES : integer := 1024;

    -- Maximum allowed data field (payload) size in bytes.
    -- Derived from the maximum frame size minus fixed overhead fields.
    -- This is the theoretical maximum; actual payload is set by TC_DATA_BYTES.
    constant TC_MAX_DATA_BYTES  : integer := TC_MAX_FRAME_BYTES
                                             - TC_HEADER_BYTES
                                             - TC_FECF_BYTES;  -- = 1019 bytes

    -- =========================================================================
    -- SECTION 4: PROJECT CONFIGURATION
    -- These values are CONFIGURABLE and specific to this implementation.
    -- They must stay within the protocol limits defined in Section 3.
    -- =========================================================================

    -- Default MAP ID for this implementation.
    -- Identifies the logical data channel within the virtual channel.
    -- Range: 0 to 63. CONFIGURABLE - set per mission channel plan.
    -- Using 0 as the default (single-MAP implementation).
    constant DEFAULT_MAP_ID   : std_logic_vector(MAP_ID_WIDTH - 1 downto 0)
                                := "000000";

    -- Chosen payload (data field) size per frame in bytes.
    -- This is the TOTAL number of bytes in the TC Data Field, including the
    -- 1-byte segment header. The usable application data per frame is therefore
    -- TC_DATA_BYTES - TC_SEG_HDR_BYTES.
    -- Must satisfy: 1 <= TC_DATA_BYTES <= TC_MAX_DATA_BYTES (1019).
    -- CONFIGURABLE - adjust to match your link budget and mission requirements.
    constant TC_DATA_BYTES       : integer := 64;

    -- Usable application data bytes per frame (after subtracting segment header).
    -- This is the number of upstream payload bytes that fit into one frame.
    -- Automatically derived - do NOT set manually.
    constant TC_APP_DATA_BYTES   : integer := TC_DATA_BYTES - TC_SEG_HDR_BYTES;
                                              -- = 63 bytes

    -- Total frame size for this implementation in bytes.
    -- Automatically derived from the chosen payload size plus fixed overhead.
    -- Do NOT set this manually - it is always computed from the values above.
    constant TC_FRAME_TOTAL_BYTES : integer := TC_HEADER_BYTES
                                              + TC_DATA_BYTES
                                              + TC_FECF_BYTES;  -- = 69 bytes

    -- =========================================================================
    -- SECTION 5: CRC-16 PARAMETERS
    -- CCSDS mandates the CCITT CRC-16 algorithm for the FECF field.
    -- Defined in CCSDS 231.0-B-4 (TC Synchronization and Channel Coding).
    -- REMOVED in this version
    -- =========================================================================

    -- CRC-16/CCITT generator polynomial: x^16 + x^12 + x^5 + 1.
    -- Represented as 0x1021 (bit 16 is implicit).
    -- constant CRC16_POLY : std_logic_vector(15 downto 0) := x"1021";

    -- Initial value of the CRC shift register before processing begins.
    -- CCSDS specifies 0xFFFF as the mandatory start value.
    -- constant CRC16_INIT : std_logic_vector(15 downto 0) := x"FFFF";

    -- =========================================================================
    -- SECTION 6: TYPES
    -- =========================================================================

    -- A single byte, used as the basic data unit throughout the design.
    subtype t_byte is std_logic_vector(7 downto 0);

    -- A complete serialized TC Transfer Frame as a byte array.
    -- Index 0 = first transmitted byte (MSB of header word 1).
    -- Index TC_FRAME_TOTAL_BYTES-1 = last byte (LSB of FECF, or last data byte
    -- if FECF is disabled).
    type t_frame is array (0 to TC_FRAME_TOTAL_BYTES - 1) of t_byte;

    -- A buffer holding exactly one frame's worth of APPLICATION data.
    -- Sized to TC_APP_DATA_BYTES (= TC_DATA_BYTES - 1) because the segment
    -- header byte occupies the first byte of the TC Data Field separately.
    -- Used internally in Segmentation_and_Frame_Generator to accumulate
    -- incoming bytes before building the full frame.
    type t_data_buf is array (0 to TC_APP_DATA_BYTES - 1) of t_byte;

    -- Structured representation of the TC Transfer Frame Primary Header.
    -- Makes it easy to assign individual fields by name before serialization.
    -- The serialize_header function converts this record into raw bytes.
    type t_tc_header is record
        tfvn          : std_logic_vector(TFVN_WIDTH - 1 downto 0);
        bypass        : std_logic;
        cc_flag       : std_logic;
        spacecraft_id : std_logic_vector(SCID_WIDTH - 1 downto 0);
        vcid          : std_logic_vector(VCID_WIDTH - 1 downto 0);
        frame_length  : std_logic_vector(FRAME_LEN_WIDTH - 1 downto 0);
        frame_seq_nr  : std_logic_vector(FSN_WIDTH - 1 downto 0);
    end record;

    -- Structured representation of the TC Segment Header.
    -- Occupies the first byte of the TC Data Field (frame_buf(5)).
    -- Present only when CC_FLAG = '0' (data frame, not control command).
    -- The serialize_seg_header function converts this record into one byte.
    type t_tc_seg_header is record
        seq_flags : std_logic_vector(SEG_FLAG_WIDTH - 1 downto 0);
        map_id    : std_logic_vector(MAP_ID_WIDTH   - 1 downto 0);
    end record;

    -- =========================================================================
    -- SECTION 6B: SEGMENT SEQUENCE FLAG CONSTANTS
    -- Defined in CCSDS 232.0-B-4, Section 4.2.1.3.
    -- Used to populate t_tc_seg_header.seq_flags.
    -- FIXED by protocol - do NOT change values.
    -- =========================================================================

    -- The complete user data unit fits entirely within this one frame.
    -- No reassembly needed on the space side.
    constant SEG_FLAG_UNSEGMENTED : std_logic_vector(SEG_FLAG_WIDTH - 1 downto 0)
                                    := "11";

    -- This frame carries the FIRST segment of a multi-frame data unit.
    -- Space side must begin accumulating a reassembly buffer.
    constant SEG_FLAG_FIRST       : std_logic_vector(SEG_FLAG_WIDTH - 1 downto 0)
                                    := "01";

    -- This frame carries a MIDDLE (continuation) segment.
    -- Space side appends to the reassembly buffer.
    constant SEG_FLAG_CONTINUATION: std_logic_vector(SEG_FLAG_WIDTH - 1 downto 0)
                                    := "00";

    -- This frame carries the LAST segment of a multi-frame data unit.
    -- Space side completes reassembly and delivers the full data unit upward.
    constant SEG_FLAG_LAST        : std_logic_vector(SEG_FLAG_WIDTH - 1 downto 0)
                                    := "10";

    -- =========================================================================
    -- SECTION 7: FUNCTION DECLARATIONS
    -- Implementations are in the package body below.
    -- =========================================================================

    -- Serializes a t_tc_header record into a 40-bit (5-byte) std_logic_vector.
    -- Bit order follows CCSDS 232.0-B-4, Section 4.1 (MSB first):
    --   Bits 39..38 : TFVN
    --   Bit  37     : Bypass Flag
    --   Bit  36     : Control Command Flag
    --   Bits 35..34 : Reserved ("00")
    --   Bits 33..24 : Spacecraft ID
    --   Bits 23..18 : Virtual Channel ID
    --   Bits 17..8  : Frame Length
    --   Bits  7..0  : Frame Sequence Number
    function serialize_header(hdr : t_tc_header)
        return std_logic_vector;  -- returns 40-bit vector (5 bytes)

    -- Serializes a t_tc_seg_header record into an 8-bit (1-byte) std_logic_vector.
    -- Bit order follows CCSDS 232.0-B-4, Section 4.2 (MSB first):
    --   Bits 7..6 : Sequence Flags
    --   Bits 5..0 : MAP ID
    -- This byte is written to frame_buf(TC_HEADER_BYTES), i.e. frame_buf(5),
    -- immediately after the primary header and before the application data.
    function serialize_seg_header(seg_hdr : t_tc_seg_header)
        return std_logic_vector;  -- returns 8-bit vector (1 byte)

end package ccsds_types_pkg;

-- =============================================================================
-- PACKAGE BODY
-- =============================================================================

package body ccsds_types_pkg is

    function serialize_header(hdr : t_tc_header)
        return std_logic_vector is
        variable result : std_logic_vector(39 downto 0);
    begin
        result := hdr.tfvn          -- bits 39..38
                & hdr.bypass        -- bit  37
                & hdr.cc_flag       -- bit  36
                & "00"              -- bits 35..34  (reserved, always "00")
                & hdr.spacecraft_id -- bits 33..24
                & hdr.vcid          -- bits 23..18
                & hdr.frame_length  -- bits 17..8
                & hdr.frame_seq_nr; -- bits  7..0
        return result;
    end function serialize_header;

    function serialize_seg_header(seg_hdr : t_tc_seg_header)
        return std_logic_vector is
        variable result : std_logic_vector(7 downto 0);
    begin
        result := seg_hdr.seq_flags  -- bits 7..6
                & seg_hdr.map_id;    -- bits 5..0
        return result;
    end function serialize_seg_header;

end package body ccsds_types_pkg;