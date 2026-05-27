----------------------------------------------------------------------------------
-- Company:
-- Engineer: 
-- 
-- Create Date: 26.05.2026 17:05:24
-- Design Name: CCSDS TC Space Segment
-- Module Name: Receiver_and_Packet_Extractor - Behavioral
-- Project Name: CCSDS TC Receiver
-- Target Devices:
-- Tool Versions:
-- Description:
--   Receives complete TC Transfer Frames from the frame_sync_and_decoding module,
--   parses the primary header and segment header, and reassembles segmented user
--   data units into a flat byte buffer.
--
--   Segmentation logic:
--     SEG_FLAG_UNSEGMENTED ( "11" ) -> single-frame PDU, output immediately
--     SEG_FLAG_FIRST       ( "01" ) -> start new reassembly buffer
--     SEG_FLAG_CONTINUATION( "00" ) -> append to current buffer
--     SEG_FLAG_LAST        ( "10" ) -> append and signal PDU complete
--
--   Inputs
--     frame_in      : one complete TC Transfer Frame (t_frame)
--     frame_valid   : pulse high for one clock cycle when frame_in is valid
--
--   Outputs
--     pdu_data      : reassembled user data buffer (t_user_data_buf)
--     pdu_length    : number of valid bytes in pdu_data
--     pdu_valid     : pulses high for one clock cycle when a PDU is complete
--     status        : current reassembly FSM status
--     error_flag    : '1' when status is an error state
--
-- Dependencies:
--   ccsds_types_pkg  (t_frame, t_byte, SEG_FLAG_*, etc.)
--   tc_extract_pkg   (t_user_data_buf, t_reassembly_status, parse_tc_header,
--                     parse_tc_seg_header, is_data_frame, is_first_segment,
--                     is_cont_segment, is_last_segment, is_unsegmented_frame,
--                     frame_app_data_bytes)
--
-- Revision:
-- Revision 0.01 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.ccsds_types_pkg.all;
use work.tc_extract_pkg.all;

entity Receiver_and_Packet_Extractor is
    port (
        -- Clock and synchronous reset (active high)
        clk         : in  std_logic;
        rst         : in  std_logic;

        -- Input: one complete decoded TC Transfer Frame
        frame_in    : in  t_frame;
        frame_valid : in  std_logic;    -- pulse high for one clock cycle

        -- Output: reassembled user data unit
        pdu_data    : out t_user_data_buf;
        pdu_length  : out t_user_data_len;  -- number of valid bytes in pdu_data
        pdu_valid   : out std_logic;        -- pulse high for one clock cycle

        -- Status / error
        status      : out t_reassembly_status;
        error_flag  : out std_logic
    );
end entity Receiver_and_Packet_Extractor;

architecture Behavioral of Receiver_and_Packet_Extractor is

    ---------------------------------------------------------------------------
    -- Internal signals
    ---------------------------------------------------------------------------

    -- Reassembly buffer and write pointer
    signal write_idx  : t_user_data_len;

    -- Current FSM state
    signal fsm_status : t_reassembly_status;

begin

    ---------------------------------------------------------------------------
    -- Main reassembly process
    ---------------------------------------------------------------------------
    reassembly_proc : process(clk)
        -- Number of application data bytes this frame contributes
        variable app_bytes : integer range 0 to TC_APP_DATA_BYTES;
        -- Loop index for copying payload bytes into buf
        variable i         : integer range 0 to TC_APP_DATA_BYTES - 1;
        -- Source offset inside frame_in (payload starts after header + seg header)
        variable src_base  : integer;
        -- Local copies of parsed headers (call functions once per frame)
        variable v_hdr     : t_tc_header;
        variable v_seg_hdr : t_tc_seg_header;
        
        variable buf        : t_user_data_buf;
    begin
        if rising_edge(clk) then
            -- Synchronous reset
            if rst = '1' then
                buf        := (others => (others => '0'));
                write_idx  <= 0;
                fsm_status <= REASM_IDLE;
                pdu_valid  <= '0';
                pdu_length <= 0;
                pdu_data   <= (others => (others => '0'));

            else
                -- Default: de-assert single-cycle signals
                pdu_valid <= '0';

                -- Only act when a new frame arrives
                if frame_valid = '1' then

                    -- Parse headers from the incoming frame
                    v_hdr     := parse_tc_header(frame_in);
                    v_seg_hdr := parse_tc_seg_header(frame_in);

                    -- Only process frames that carry data (CC_FLAG = '0')
                    if is_data_frame(v_hdr) then

                        -- Pre-compute for this frame
                        app_bytes := frame_app_data_bytes(v_hdr);
                        -- Payload bytes inside frame_in start at:
                        --   TC_HEADER_BYTES (primary header) + TC_SEG_HDR_BYTES (segment header)
                        src_base  := TC_HEADER_BYTES + TC_SEG_HDR_BYTES;

                        ----------------------------------------------------------------
                        -- Segmentation FSM
                        ----------------------------------------------------------------
                        if is_unsegmented_frame(v_seg_hdr) then
                            ----------------------------------------------------------------
                            -- UNSEGMENTED: entire PDU fits in this single frame.
                            ----------------------------------------------------------------
                            for i in 0 to app_bytes - 1 loop
                                buf(i) := frame_in(src_base + i);
                            end loop;
                            pdu_data   <= buf;        -- next cycle content
                            pdu_length <= app_bytes;
                            pdu_valid  <= '1';
                            write_idx  <= 0;
                            fsm_status <= REASM_COMPLETE;

                        elsif is_first_segment(v_seg_hdr) then
                            ----------------------------------------------------------------
                            -- FIRST: begin a new reassembly.
                            ----------------------------------------------------------------
                            for i in 0 to app_bytes - 1 loop
                                buf(i) := frame_in(src_base + i);
                            end loop;
                            write_idx  <= app_bytes;
                            fsm_status <= REASM_IN_PROGRESS;

                        elsif is_cont_segment(v_seg_hdr) then
                            ----------------------------------------------------------------
                            -- CONTINUATION: append to existing buffer.
                            ----------------------------------------------------------------
                            if fsm_status /= REASM_IN_PROGRESS then
                                -- Protocol error: CONT without FIRST
                                fsm_status <= REASM_ERROR_SEQ;
                                write_idx  <= 0;
                            elsif write_idx + app_bytes > MAX_USER_DATA_BYTES then
                                -- Buffer overflow
                                fsm_status <= REASM_ERROR_OVERFLOW;
                                write_idx  <= 0;
                            else
                                for i in 0 to app_bytes - 1 loop
                                    buf(write_idx + i) := frame_in(src_base + i);
                                end loop;
                                write_idx  <= write_idx + app_bytes;
                                fsm_status <= REASM_IN_PROGRESS;
                            end if;

                        elsif is_last_segment(v_seg_hdr) then
                            ----------------------------------------------------------------
                            -- LAST: append final bytes, signal PDU complete.
                            ----------------------------------------------------------------
                            if fsm_status /= REASM_IN_PROGRESS then
                                -- Protocol error: LAST without FIRST
                                fsm_status <= REASM_ERROR_SEQ;
                                write_idx  <= 0;
                            elsif write_idx + app_bytes > MAX_USER_DATA_BYTES then
                                -- Buffer overflow on last segment
                                fsm_status <= REASM_ERROR_OVERFLOW;
                                write_idx  <= 0;
                            else
                                for i in 0 to app_bytes - 1 loop
                                    buf(write_idx + i) := frame_in(src_base + i);
                                end loop;
                                pdu_data   <= buf;
                                pdu_length <= write_idx + app_bytes;
                                pdu_valid  <= '1';
                                write_idx  <= 0;
                                fsm_status <= REASM_COMPLETE;
                            end if;

                        end if; -- seg_flag cases

                    end if; -- is_data_frame

                else
                    -- No new frame: if we just completed, transition back to IDLE
                    if fsm_status = REASM_COMPLETE then
                        fsm_status <= REASM_IDLE;
                    end if;
                end if; -- frame_valid

            end if; -- rst
        end if; -- rising_edge
    end process reassembly_proc;

    ---------------------------------------------------------------------------
    -- Drive output ports from internal signals
    ---------------------------------------------------------------------------
    status     <= fsm_status;
    error_flag <= '1' when (fsm_status = REASM_ERROR_OVERFLOW or
                             fsm_status = REASM_ERROR_SEQ)
                  else '0';

end architecture Behavioral;