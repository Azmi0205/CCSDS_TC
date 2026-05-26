-- =============================================================================
-- tb_segmentation_and_frame_generator.vhd
-- Testbench - segmentation_and_frame_generator
--
-- Tool targets : Vivado Simulator (xsim) / ModelSim-Intel (vsim)
-- VHDL standard: 2008
--
-- Test sequence (four frames total):
--
--   Frame 1 - UNSEGMENTED  : 10 data bytes, i_last on the 10th byte.
--                            Segment flag in frame_buf(5)[7:6] = "11"
--
--   Frame 2 - FIRST        : 63 data bytes (full TC_APP_DATA_BYTES), no i_last.
--                            Segment flag = "01"
--
--   Frame 3 - CONTINUATION : 63 data bytes, no i_last.
--                            Segment flag = "00"
--
--   Frame 4 - LAST         : 20 data bytes, i_last on the 20th byte.
--                            Segment flag = "10"
--
-- Key observation signals
-- ───────────────────────
--   captured_frame   - type t_frame (69 bytes).  Only written while
--                      o_frame_valid = '1'; holds the previous value in
--                      between frames.  Add all 69 bytes to the waveform
--                      for a complete per-frame view.
--
--   frame_number     - natural counter, incremented once per complete
--                      frame (on the rising edge of o_frame_valid).
--                      Useful as a waveform "epoch" marker.
--
-- Compile order (same library "work"):
--   1. ccsds_types_pkg.vhd
--   2. tc_frame_pkg.vhd
--   3. segmentation_and_frame_generator.vhd
--   4. tb_segmentation_and_frame_generator.vhd  (this file)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.ccsds_types_pkg.all;
use work.tc_frame_pkg.all;

entity tb_segmentation_and_frame_generator is
    -- No ports - pure self-contained testbench
end entity tb_segmentation_and_frame_generator;

architecture sim of tb_segmentation_and_frame_generator is

    -- =========================================================================
    -- Simulation parameters
    -- =========================================================================
    constant C_CLK_PERIOD     : time    := 10 ns;   -- 100 MHz
    constant C_RESET_CYCLES   : natural := 6;        -- reset assertion length
    constant C_ACK_DELAY_CYC  : natural := 3;        -- cycles from frame_valid
                                                     --   to i_frame_ack

    -- Payload byte counts for each test case
    constant C_UNSEG_BYTES    : natural := 10;
    constant C_LAST_SEG_BYTES : natural := 20;

    -- =========================================================================
    -- DUT interface
    -- =========================================================================
    signal clk           : std_logic := '0';
    signal rst           : std_logic := '1';

    -- Quasi-static header fields (held constant throughout the simulation)
    signal i_bypass      : std_logic := '0';
    signal i_cc_flag     : std_logic := '0';
    signal i_vcid        : std_logic_vector(VCID_WIDTH - 1 downto 0)
                             := (others => '0');

    -- Upstream byte stream
    signal i_data        : std_logic_vector(7 downto 0) := (others => '0');
    signal i_valid       : std_logic := '0';
    signal o_ready       : std_logic;
    signal i_last        : std_logic := '0';

    -- Downstream frame interface
    signal o_frame       : t_frame;
    signal o_frame_valid : std_logic;
    signal i_frame_ack   : std_logic := '0';

    -- =========================================================================
    -- Observation / debug signals
    -- =========================================================================
    -- captured_frame: written from o_frame only while o_frame_valid = '1'.
    -- Between frames it retains the previously captured value, giving the
    -- waveform a clean "one snapshot per frame" appearance.
    signal captured_frame : t_frame  := (others => (others => '0'));

    -- frame_number: increments on the first rising edge of each new
    -- o_frame_valid pulse.  Use as a waveform epoch marker.
    signal frame_number   : natural  := 0;

    -- =========================================================================
    -- Utility procedures (all sequential - call from processes only)
    -- =========================================================================

    -- Wait for exactly 'n' rising edges of clk.
    procedure wait_cycles (
        constant n   : in natural;
        signal   clk : in std_logic
    ) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk);
        end loop;
    end procedure wait_cycles;

    -- Drive one byte into the DUT.
    --
    -- Drives o_data / o_valid / o_last and holds them until a rising edge
    -- at which i_ready = '1' (DUT in S_IDLE or S_FILL).  The DUT samples
    -- the byte on that edge; the procedure then deasserts the outputs.
    procedure send_byte (
        constant byte_val : in  std_logic_vector(7 downto 0);
        constant is_last  : in  std_logic;
        signal   clk      : in  std_logic;
        signal   o_data   : out std_logic_vector(7 downto 0);
        signal   o_valid  : out std_logic;
        signal   o_last   : out std_logic;
        signal   i_ready  : in  std_logic
    ) is
    begin
        -- Present the byte
        o_data  <= byte_val;
        o_valid <= '1';
        o_last  <= is_last;
        -- Block until the DUT is ready to accept it
        wait until rising_edge(clk) and i_ready = '1';
        -- Deassert - DUT has latched the byte at this rising edge
        o_valid <= '0';
        o_last  <= '0';
        o_data  <= (others => '0');
    end procedure send_byte;

    -- Send 'count' consecutive bytes.
    --   base_val   : value of the first byte (each successive byte is +1 mod 256)
    --   mark_last  : when true, i_last is asserted only on the very last byte;
    --                when false, i_last is never asserted (mid-message segments)
    procedure send_stream (
        constant count     : in  natural;
        constant base_val  : in  natural;
        constant mark_last : in  boolean;
        signal   clk       : in  std_logic;
        signal   o_data    : out std_logic_vector(7 downto 0);
        signal   o_valid   : out std_logic;
        signal   o_last    : out std_logic;
        signal   i_ready   : in  std_logic
    ) is
        variable bval   : std_logic_vector(7 downto 0);
        variable is_lst : std_logic;
    begin
        for idx in 0 to count - 1 loop
            bval   := std_logic_vector(to_unsigned((base_val + idx) mod 256, 8));
            if mark_last and (idx = count - 1) then
                is_lst := '1';
            else
                is_lst := '0';
            end if;
            send_byte(bval, is_lst, clk, o_data, o_valid, o_last, i_ready);
        end loop;
    end procedure send_stream;

    -- Wait for o_frame_valid to go high (or, if it is already high, catch the
    -- next rising clock edge), then assert i_frame_ack after 'delay_cyc'
    -- additional clock cycles, and hold it for one cycle.
    procedure ack_frame (
        constant delay_cyc : in  natural;
        signal   clk       : in  std_logic;
        signal   fv        : in  std_logic;
        signal   ack       : out std_logic
    ) is
    begin
        -- Wait for DUT to enter S_OUTPUT (o_frame_valid = '1')
        wait until rising_edge(clk) and fv = '1';
        -- Optional hold to let a receiver observe the frame
        wait_cycles(delay_cyc, clk);
        -- Pulse acknowledge for exactly one clock cycle
        ack <= '1';
        wait until rising_edge(clk);
        ack <= '0';
    end procedure ack_frame;

begin

    -- =========================================================================
    -- Clock generation  (free-running)
    -- =========================================================================
    clk <= not clk after C_CLK_PERIOD / 2;

    -- =========================================================================
    -- DUT instantiation
    -- =========================================================================
    u_dut : entity work.segmentation_and_frame_generator
        generic map (
            G_SCID   => (others => '0'),
            G_MAP_ID => (others => '0')
        )
        port map (
            clk           => clk,
            rst           => rst,
            i_bypass      => i_bypass,
            i_cc_flag     => i_cc_flag,
            i_vcid        => i_vcid,
            i_data        => i_data,
            i_valid       => i_valid,
            o_ready       => o_ready,
            i_last        => i_last,
            o_frame       => o_frame,
            o_frame_valid => o_frame_valid,
            i_frame_ack   => i_frame_ack
        );

    -- =========================================================================
    -- Frame capture process
    --
    -- captured_frame is updated on every rising edge where o_frame_valid = '1'.
    -- Because o_frame is stable throughout S_OUTPUT, the captured value is
    -- constant for the entire valid window and changes only when a new frame
    -- is presented.
    -- frame_number increments once per frame (detected on the first cycle of
    -- each o_frame_valid pulse via the was_valid edge detector).
    -- =========================================================================
    p_capture : process (clk)
        variable was_valid : std_logic := '0';
    begin
        if rising_edge(clk) then
            if o_frame_valid = '1' then
                -- Latch the complete frame
                captured_frame <= o_frame;
                -- Count new frames (rising edge of o_frame_valid only)
                if was_valid = '0' then
                    frame_number <= frame_number + 1;
                end if;
            end if;
            was_valid := o_frame_valid;
        end if;
    end process p_capture;

    -- =========================================================================
    -- Stimulus process
    -- =========================================================================
    p_stim : process
    begin

        -- ---------------------------------------------------------------------
        -- Apply synchronous reset
        -- ---------------------------------------------------------------------
        rst <= '1';
        wait_cycles(C_RESET_CYCLES, clk);
        rst <= '0';
        wait_cycles(2, clk);

        -- =====================================================================
        -- FRAME 1 - UNSEGMENTED
        --
        -- Send C_UNSEG_BYTES (10) bytes.  i_last is asserted on byte #10.
        -- is_first_seg='1', last_seen='1'  =>  seg_flags = "11"
        -- Frame Sequence Number (FSN) = 0x00
        --
        -- Expected frame_buf(5) : "11_XXXX_XX"  (bits 7:6 = "11")
        -- =====================================================================
        report "TB [FRAME 1]: Sending UNSEGMENTED frame ("
               & integer'image(C_UNSEG_BYTES) & " bytes) ...";

        send_stream(
            count     => C_UNSEG_BYTES,
            base_val  => 16#A0#,        -- bytes 0xA0 .. 0xA9
            mark_last => true,
            clk       => clk,
            o_data    => i_data,
            o_valid   => i_valid,
            o_last    => i_last,
            i_ready   => o_ready
        );

        ack_frame(C_ACK_DELAY_CYC, clk, o_frame_valid, i_frame_ack);

        -- Verify segment flag (bits 7:6 of segment header byte = frame_buf(5))
        assert captured_frame(5)(7 downto 6) = SEG_FLAG_UNSEGMENTED
            report "FRAME 1 FAIL: Expected UNSEGMENTED flag (""11"") in " &
                   "frame_buf(5)[7:6]; got " &
                   std_logic'image(captured_frame(5)(7)) &
                   std_logic'image(captured_frame(5)(6))
            severity error;

        report "TB [FRAME 1]: Acknowledged. FSN=0x00, seg_flag=""11"" (UNSEGMENTED).";
        wait_cycles(2, clk);

        -- =====================================================================
        -- FRAME 2 - FIRST segment of a multi-frame message
        --
        -- Send TC_APP_DATA_BYTES (63) bytes with no i_last.
        -- Buffer fills completely, triggering S_BUILD_HDR without last_seen.
        -- is_first_seg='1', last_seen='0'  =>  seg_flags = "01"
        -- FSN = 0x01
        --
        -- Expected frame_buf(5) : "01_XXXX_XX"  (bits 7:6 = "01")
        -- =====================================================================
        report "TB [FRAME 2]: Sending FIRST segment ("
               & integer'image(TC_APP_DATA_BYTES) & " bytes, no i_last) ...";

        send_stream(
            count     => TC_APP_DATA_BYTES,
            base_val  => 16#00#,        -- bytes 0x00 .. 0x3E
            mark_last => false,         -- buffer-full triggers frame, not i_last
            clk       => clk,
            o_data    => i_data,
            o_valid   => i_valid,
            o_last    => i_last,
            i_ready   => o_ready
        );

        ack_frame(C_ACK_DELAY_CYC, clk, o_frame_valid, i_frame_ack);

        assert captured_frame(5)(7 downto 6) = SEG_FLAG_FIRST
            report "FRAME 2 FAIL: Expected FIRST flag (""01"") in " &
                   "frame_buf(5)[7:6]; got " &
                   std_logic'image(captured_frame(5)(7)) &
                   std_logic'image(captured_frame(5)(6))
            severity error;

        report "TB [FRAME 2]: Acknowledged. FSN=0x01, seg_flag=""01"" (FIRST).";
        wait_cycles(2, clk);

        -- =====================================================================
        -- FRAME 3 - CONTINUATION segment
        --
        -- Send TC_APP_DATA_BYTES (63) bytes with no i_last.
        -- is_first_seg='0' (cleared after FIRST), last_seen='0'
        --   =>  seg_flags = "00"
        -- FSN = 0x02
        --
        -- Expected frame_buf(5) : "00_XXXX_XX"  (bits 7:6 = "00")
        -- =====================================================================
        report "TB [FRAME 3]: Sending CONTINUATION segment ("
               & integer'image(TC_APP_DATA_BYTES) & " bytes, no i_last) ...";

        send_stream(
            count     => TC_APP_DATA_BYTES,
            base_val  => 16#40#,        -- bytes 0x40 .. 0x7E
            mark_last => false,
            clk       => clk,
            o_data    => i_data,
            o_valid   => i_valid,
            o_last    => i_last,
            i_ready   => o_ready
        );

        ack_frame(C_ACK_DELAY_CYC, clk, o_frame_valid, i_frame_ack);

        assert captured_frame(5)(7 downto 6) = SEG_FLAG_CONTINUATION
            report "FRAME 3 FAIL: Expected CONTINUATION flag (""00"") in " &
                   "frame_buf(5)[7:6]; got " &
                   std_logic'image(captured_frame(5)(7)) &
                   std_logic'image(captured_frame(5)(6))
            severity error;

        report "TB [FRAME 3]: Acknowledged. FSN=0x02, seg_flag=""00"" (CONTINUATION).";
        wait_cycles(2, clk);

        -- =====================================================================
        -- FRAME 4 - LAST segment
        --
        -- Send C_LAST_SEG_BYTES (20) bytes.  i_last is asserted on byte #20.
        -- is_first_seg='0', last_seen='1'  =>  seg_flags = "10"
        -- FSN = 0x03
        -- Bytes 20..62 in frame_buf are zero-padded (cleared in S_IDLE/reset).
        --
        -- Expected frame_buf(5) : "10_XXXX_XX"  (bits 7:6 = "10")
        -- =====================================================================
        report "TB [FRAME 4]: Sending LAST segment ("
               & integer'image(C_LAST_SEG_BYTES) & " bytes, i_last on final) ...";

        send_stream(
            count     => C_LAST_SEG_BYTES,
            base_val  => 16#80#,        -- bytes 0x80 .. 0x93
            mark_last => true,
            clk       => clk,
            o_data    => i_data,
            o_valid   => i_valid,
            o_last    => i_last,
            i_ready   => o_ready
        );

        ack_frame(C_ACK_DELAY_CYC, clk, o_frame_valid, i_frame_ack);

        assert captured_frame(5)(7 downto 6) = SEG_FLAG_LAST
            report "FRAME 4 FAIL: Expected LAST flag (""10"") in " &
                   "frame_buf(5)[7:6]; got " &
                   std_logic'image(captured_frame(5)(7)) &
                   std_logic'image(captured_frame(5)(6))
            severity error;

        report "TB [FRAME 4]: Acknowledged. FSN=0x03, seg_flag=""10"" (LAST).";

        -- =====================================================================
        -- Drain and end simulation
        -- =====================================================================
        wait_cycles(20, clk);
        report "TB: All four frames transmitted and verified successfully."
            severity note;

        -- Stop simulation cleanly in both xsim and vsim
        assert false
            report "TB: Simulation complete - this assertion stops the run."
            severity failure;

        wait;   -- Safety; never reached
    end process p_stim;

end architecture sim;