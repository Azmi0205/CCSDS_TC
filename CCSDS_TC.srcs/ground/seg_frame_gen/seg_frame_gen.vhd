-- =============================================================================
-- segmentation_and_frame_generator.vhd
-- Ground Segment - TC Uplink
--
-- Receives pre-processed bytes from Frame_Sync_and_Encoding via a simple
-- internal valid/ready/last handshake. Assembles a CCSDS TC Transfer Frame
-- (header + segment header + data) and presents the complete frame to the
-- Transmission Interface via a valid/ack handshake.
--
-- Frame layout (TC_FRAME_TOTAL_BYTES = 69 bytes):
--   [0..4]  : TC Primary Header         (5 bytes, TC_HEADER_BYTES)
--   [5]     : TC Segment Header         (1 byte,  TC_SEG_HDR_BYTES)
--   [6..68] : Application Data          (63 bytes, TC_APP_DATA_BYTES)
--
-- Segmentation flags (written into frame_buf(5) bits [7:6]):
--   "11" UNSEGMENTED  : entire message fits in one frame
--   "01" FIRST        : first segment of a multi-frame message
--   "00" CONTINUATION : middle segment
--   "10" LAST         : final segment, receiver reassembles
--
-- Dependencies:
--   work.ccsds_types_pkg   (src/common/)
--   work.tc_frame_pkg      (src/ground/seg_frame_gen/)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.ccsds_types_pkg.all;
use work.tc_frame_pkg.all;

entity segmentation_and_frame_generator is
    generic (
        G_SCID   : std_logic_vector(SCID_WIDTH  - 1 downto 0) := DEFAULT_SCID;
        G_MAP_ID : std_logic_vector(MAP_ID_WIDTH - 1 downto 0) := DEFAULT_MAP_ID
    );
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;

        -- Quasi-static TC header configuration
        i_bypass      : in  std_logic;
        i_cc_flag     : in  std_logic;
        i_vcid        : in  std_logic_vector(VCID_WIDTH - 1 downto 0);

        -- Input: from Frame_Sync_and_Encoding
        i_data        : in  std_logic_vector(7 downto 0);
        i_valid       : in  std_logic;
        o_ready       : out std_logic;
        i_last        : in  std_logic;  -- last byte of this data unit

        -- Output: complete TC frame to Transmission_Interface
        o_frame       : out t_frame;
        o_frame_valid : out std_logic;
        i_frame_ack   : in  std_logic   -- TX interface has latched the frame
    );
end entity segmentation_and_frame_generator;

architecture rtl of segmentation_and_frame_generator is

    -- -------------------------------------------------------------------------
    -- FSM
    -- -------------------------------------------------------------------------
    type t_state is (
        S_IDLE,       -- waiting for first input byte, clearing data buffer
        S_FILL,       -- accumulating payload bytes from upstream
        S_BUILD_HDR,  -- serialize TC primary + segment header into frame_buf
        S_COPY_DATA,  -- copy data_buf into frame_buf[6..68]
        S_OUTPUT      -- hold complete frame until Transmission Interface acks
    );
    signal state : t_state := S_IDLE;

    -- -------------------------------------------------------------------------
    -- Buffers
    -- -------------------------------------------------------------------------
    -- Sized to TC_APP_DATA_BYTES (63) - segment header occupies frame_buf(5)
    -- separately, so application data never goes into data_buf index 0 of the
    -- old TC_DATA_BYTES-sized buffer.
    signal data_buf  : t_data_buf;                                  -- 63 bytes
    signal data_cnt  : integer range 0 to TC_APP_DATA_BYTES := 0;  -- bytes received
    signal frame_buf : t_frame;                                     -- 69 bytes

    -- Frame Sequence Number - 8-bit, wraps at 256 per CCSDS 232.0-B
    signal fsn_reg   : unsigned(FSN_WIDTH - 1 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- Internal control signals
    -- -------------------------------------------------------------------------
    -- Latched copy of i_last so it survives the transition to S_BUILD_HDR
    signal last_seen      : std_logic := '0';

    -- Set on the first segment of every new message; cleared after that
    -- segment's frame is emitted. Used to compute the sequence flags.
    signal is_first_seg   : std_logic := '1';

    -- Copy index used in S_COPY_DATA
    signal copy_idx       : integer range 0 to TC_APP_DATA_BYTES - 1 := 0;

begin

    -- =========================================================================
    -- Output assignments
    -- =========================================================================
    o_frame       <= frame_buf;
    o_frame_valid <= '1' when state = S_OUTPUT else '0';
    -- Accept new bytes only while filling the buffer
    o_ready       <= '1' when state = S_FILL or state = S_IDLE else '0';

    -- =========================================================================
    -- Main FSM process
    -- =========================================================================
    p_fsm : process(clk)
        variable hdr       : t_tc_header;
        variable seg_hdr   : t_tc_seg_header;
        variable hdr_bits  : std_logic_vector(39 downto 0);
        variable seg_bits  : std_logic_vector(7 downto 0);
        variable frame_len : std_logic_vector(FRAME_LEN_WIDTH - 1 downto 0);
        variable seq_flags : std_logic_vector(SEG_FLAG_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state        <= S_IDLE;
                data_cnt     <= 0;
                copy_idx     <= 0;
                last_seen    <= '0';
                is_first_seg <= '1';
                fsn_reg      <= (others => '0');
                -- Clear frame buffer and data buffer
                for i in 0 to TC_FRAME_TOTAL_BYTES - 1 loop
                    frame_buf(i) <= (others => '0');
                end loop;
                for i in 0 to TC_APP_DATA_BYTES - 1 loop
                    data_buf(i) <= (others => '0');
                end loop;

            else
                case state is

                    -- ---------------------------------------------------------
                    -- S_IDLE: clear the data buffer, wait for first valid byte.
                    -- is_first_seg is NOT cleared here - it persists from the
                    -- previous S_OUTPUT so the first segment of a new message
                    -- is always correctly flagged.
                    -- ---------------------------------------------------------
                    when S_IDLE =>
                        last_seen <= '0';
                        data_cnt  <= 0;
                        for i in 0 to TC_APP_DATA_BYTES - 1 loop
                            data_buf(i) <= (others => '0');
                        end loop;

                        if i_valid = '1' then
                            data_buf(0) <= i_data;
                            data_cnt    <= 1;
                            last_seen   <= i_last;
                            if i_last = '1' or TC_APP_DATA_BYTES = 1 then
                                state <= S_BUILD_HDR;
                            else
                                state <= S_FILL;
                            end if;
                        end if;

                    -- ---------------------------------------------------------
                    -- S_FILL: accumulate bytes until buffer full or i_last
                    -- ---------------------------------------------------------
                    when S_FILL =>
                        if i_valid = '1' then
                            data_buf(data_cnt) <= i_data;
                            data_cnt           <= data_cnt + 1;

                            if i_last = '1' or data_cnt = TC_APP_DATA_BYTES - 1 then
                                last_seen <= i_last;
                                state     <= S_BUILD_HDR;
                            end if;
                        end if;

                    -- ---------------------------------------------------------
                    -- S_BUILD_HDR: build TC primary header (frame_buf[0..4])
                    --              and TC segment header   (frame_buf[5]).
                    --
                    -- Sequence flag logic:
                    --   is_first_seg=1, last_seen=1  -> UNSEGMENTED ("11")
                    --   is_first_seg=1, last_seen=0  -> FIRST       ("01")
                    --   is_first_seg=0, last_seen=0  -> CONTINUATION("00")
                    --   is_first_seg=0, last_seen=1  -> LAST        ("10")
                    -- ---------------------------------------------------------
                    when S_BUILD_HDR =>

                        -- Compute sequence flags
                        if is_first_seg = '1' and last_seen = '1' then
                            seq_flags := SEG_FLAG_UNSEGMENTED;
                        elsif is_first_seg = '1' and last_seen = '0' then
                            seq_flags := SEG_FLAG_FIRST;
                        elsif is_first_seg = '0' and last_seen = '0' then
                            seq_flags := SEG_FLAG_CONTINUATION;
                        else  -- is_first_seg='0', last_seen='1'
                            seq_flags := SEG_FLAG_LAST;
                        end if;

                        -- Build and serialize TC primary header
                        frame_len := std_logic_vector(
                            to_unsigned(TC_FRAME_TOTAL_BYTES - 1, FRAME_LEN_WIDTH));

                        hdr := make_header(
                            bypass    => i_bypass,
                            cc_flag   => i_cc_flag,
                            scid      => G_SCID,
                            vcid      => i_vcid,
                            frame_len => frame_len,
                            fsn       => std_logic_vector(fsn_reg)
                        );

                        hdr_bits := serialize_header(hdr);

                        frame_buf(0) <= hdr_bits(39 downto 32);
                        frame_buf(1) <= hdr_bits(31 downto 24);
                        frame_buf(2) <= hdr_bits(23 downto 16);
                        frame_buf(3) <= hdr_bits(15 downto  8);
                        frame_buf(4) <= hdr_bits( 7 downto  0);

                        -- Build and serialize TC segment header into frame_buf(5)
                        seg_hdr.seq_flags := seq_flags;
                        seg_hdr.map_id    := G_MAP_ID;

                        seg_bits  := serialize_seg_header(seg_hdr);
                        frame_buf(TC_HEADER_BYTES) <= seg_bits;  -- index 5

                        copy_idx <= 0;
                        state    <= S_COPY_DATA;

                    -- ---------------------------------------------------------
                    -- S_COPY_DATA: move data_buf into frame_buf[6..68].
                    -- Offset by TC_HEADER_BYTES + TC_SEG_HDR_BYTES (= 6) to
                    -- leave room for both headers at the front of the frame.
                    -- Unused tail bytes are already zero from S_IDLE / reset.
                    -- ---------------------------------------------------------
                    when S_COPY_DATA =>
                        frame_buf(TC_HEADER_BYTES + TC_SEG_HDR_BYTES + copy_idx)
                            <= data_buf(copy_idx);

                        if copy_idx = TC_APP_DATA_BYTES - 1 then
                            fsn_reg      <= fsn_reg + 1;
                            -- After this frame is sent, the next segment of the
                            -- same message is no longer the first one.
                            is_first_seg <= '0';
                            -- But if this was the last segment (or unsegmented),
                            -- reset is_first_seg so the next MESSAGE starts fresh.
                            if last_seen = '1' then
                                is_first_seg <= '1';
                            end if;
                            state <= S_OUTPUT;
                        else
                            copy_idx <= copy_idx + 1;
                        end if;

                    -- ---------------------------------------------------------
                    -- S_OUTPUT: hold frame until TX interface acknowledges
                    -- ---------------------------------------------------------
                    when S_OUTPUT =>
                        if i_frame_ack = '1' then
                            state <= S_IDLE;
                        end if;

                    when others =>
                        state <= S_IDLE;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;