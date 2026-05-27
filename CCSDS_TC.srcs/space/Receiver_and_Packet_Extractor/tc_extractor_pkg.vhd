-- src/space/packet_extract/tc_extract_pkg.vhd
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.ccsds_types_pkg.all;  -- reuse t_frame, t_tc_header, t_tc_seg_header, etc.

package tc_extract_pkg is

    -------------------------------------------------------------------------
    -- SECTION 1: REASSEMBLY / BUFFER CONFIGURATION
    -------------------------------------------------------------------------

    -- Maximum size (in bytes) of one reassembled user data unit on the space side.
    -- This should match the maximum application PDU size used by the
    -- Segmentation_and_Frame_Generator on the ground side.
    --
    -- Example:
    --   With TC_APP_DATA_BYTES = 63 bytes per frame and at most 16 frames
    --   in one segmented user data unit, we get 16 * 63 = 1008 bytes.
    --
    constant MAX_SEGMENTS_PER_PDU : integer := 16;
    constant MAX_USER_DATA_BYTES  : integer := MAX_SEGMENTS_PER_PDU * TC_APP_DATA_BYTES;

    -- A buffer large enough to hold one complete reassembled user data unit.
    subtype t_user_data_len is natural range 0 to MAX_USER_DATA_BYTES;
    type t_user_data_buf is array (0 to MAX_USER_DATA_BYTES - 1) of t_byte;

    -------------------------------------------------------------------------
    -- SECTION 2: STATUS / ERROR ENUMERATIONS
    -------------------------------------------------------------------------

    -- Reassembly status codes for the packet extractor state machine.
    type t_reassembly_status is (
        REASM_IDLE,          -- No PDU currently being assembled
        REASM_IN_PROGRESS,   -- PDU currently being built
        REASM_COMPLETE,      -- PDU just completed with LAST segment
        REASM_ERROR_OVERFLOW,-- Incoming data exceeded MAX_USER_DATA_BYTES
        REASM_ERROR_SEQ      -- Protocol/sequence error (e.g. CONT without FIRST)
    );

    -------------------------------------------------------------------------
    -- SECTION 3: HELPER FUNCTIONS
    -------------------------------------------------------------------------

    -- Extract primary header from a raw t_frame.
    -- This is the inverse operation of serialize_header().
    -- Frame index 0 corresponds to the first transmitted byte of the header.
    function parse_tc_header(
        frame : t_frame
    ) return t_tc_header;

    -- Extract the TC segment header from a raw t_frame.
    -- This reads the first data-field byte at index TC_HEADER_BYTES.
    function parse_tc_seg_header(
        frame : t_frame
    ) return t_tc_seg_header;

    -- Return TRUE if frame carries a segment (i.e. cc_flag = '0').
    function is_data_frame(
        hdr : t_tc_header
    ) return boolean;

    -- Return TRUE if the seg_header indicates FIRST / CONT / LAST / UNSEGMENTED.
    -- These helpers make the extractor FSM more readable.
    function is_first_segment     (seg : t_tc_seg_header) return boolean;
    function is_cont_segment      (seg : t_tc_seg_header) return boolean;
    function is_last_segment      (seg : t_tc_seg_header) return boolean;
    function is_unsegmented_frame (seg : t_tc_seg_header) return boolean;

    -- Compute how many application data bytes are present in this frame.
    -- For the current fixed-size implementation, this is identical for every
    -- data frame: TC_APP_DATA_BYTES for ALL segmented frames except possibly
    -- the LAST one if you later support variable fill.
    --
    -- Still useful as an abstraction if you later introduce padding/fill logic.
    function frame_app_data_bytes(
        hdr : t_tc_header
    ) return integer;

end package tc_extract_pkg;


package body tc_extract_pkg is

    -------------------------------------------------------------------------
    -- parse_tc_header
    -------------------------------------------------------------------------
    function parse_tc_header(
        frame : t_frame
    ) return t_tc_header is
        variable hdr        : t_tc_header;
        variable header_vec : std_logic_vector(39 downto 0);
    begin
        -- Rebuild the 40-bit header vector from the first 5 bytes.
        header_vec :=
              frame(0)
            & frame(1)
            & frame(2)
            & frame(3)
            & frame(4);

        -- Slice fields out in the same order used by serialize_header().
        hdr.tfvn          := header_vec(39 downto 38);
        hdr.bypass        := header_vec(37);
        hdr.cc_flag       := header_vec(36);
        hdr.spacecraft_id := header_vec(33 downto 24);
        hdr.vcid          := header_vec(23 downto 18);
        hdr.frame_length  := header_vec(17 downto 8);
        hdr.frame_seq_nr  := header_vec(7 downto 0);

        return hdr;
    end function parse_tc_header;

    -------------------------------------------------------------------------
    -- parse_tc_seg_header
    -------------------------------------------------------------------------
    function parse_tc_seg_header(
        frame : t_frame
    ) return t_tc_seg_header is
        variable seg     : t_tc_seg_header;
        variable seg_vec : std_logic_vector(7 downto 0);
    begin
        -- Segment header is the first byte of the data field.
        seg_vec := frame(TC_HEADER_BYTES);

        seg.seq_flags := seg_vec(7 downto 6);
        seg.map_id    := seg_vec(5 downto 0);

        return seg;
    end function parse_tc_seg_header;

    -------------------------------------------------------------------------
    -- is_data_frame
    -------------------------------------------------------------------------
    function is_data_frame(
        hdr : t_tc_header
    ) return boolean is
    begin
        -- CC_FLAG = '0' means frame carries a TC segment in the data field.
        return (hdr.cc_flag = '0');
    end function is_data_frame;

    -------------------------------------------------------------------------
    -- Segment flag helpers
    -------------------------------------------------------------------------
    function is_first_segment(
        seg : t_tc_seg_header
    ) return boolean is
    begin
        return (seg.seq_flags = SEG_FLAG_FIRST);
    end function is_first_segment;

    function is_cont_segment(
        seg : t_tc_seg_header
    ) return boolean is
    begin
        return (seg.seq_flags = SEG_FLAG_CONTINUATION);
    end function is_cont_segment;

    function is_last_segment(
        seg : t_tc_seg_header
    ) return boolean is
    begin
        return (seg.seq_flags = SEG_FLAG_LAST);
    end function is_last_segment;

    function is_unsegmented_frame(
        seg : t_tc_seg_header
    ) return boolean is
    begin
        return (seg.seq_flags = SEG_FLAG_UNSEGMENTED);
    end function is_unsegmented_frame;

    -------------------------------------------------------------------------
    -- frame_app_data_bytes
    -------------------------------------------------------------------------
    function frame_app_data_bytes(
        hdr : t_tc_header
    ) return integer is
    begin
        -- For now, all frames are the same size in this implementation, and
        -- we know that:
        --   TC_DATA_BYTES = TC_SEG_HDR_BYTES + TC_APP_DATA_BYTES
        -- so the application payload per frame is TC_APP_DATA_BYTES.
        -- If you later allow different frame lengths, you can decode
        -- hdr.frame_length here and compute the effective app data size.
        return TC_APP_DATA_BYTES;
    end function frame_app_data_bytes;

end package body tc_extract_pkg;