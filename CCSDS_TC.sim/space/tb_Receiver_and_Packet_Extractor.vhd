-- tb_Receiver_and_Packet_Extractor.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.ccsds_types_pkg.all;
use work.tc_extract_pkg.all;

entity tb_Receiver_and_Packet_Extractor is
end entity;

architecture sim of tb_Receiver_and_Packet_Extractor is

    constant CLK_PERIOD : time := 10 ns;

    -- DUT signals
    signal clk         : std_logic := '0';
    signal rst         : std_logic := '1';
    signal frame_in    : t_frame;
    signal frame_valid : std_logic := '0';

    signal pdu_data    : t_user_data_buf;
    signal pdu_length  : t_user_data_len;
    signal pdu_valid   : std_logic;
    signal status      : t_reassembly_status;
    signal error_flag  : std_logic;

    -- Observable "latched" PDU output that only changes on full PDU
    signal observed_pdu_data   : t_user_data_buf := (others => (others => '0'));
    signal observed_pdu_length : t_user_data_len := 0;

    -- ---------------------------------------------------------------
    -- FIX A: Procedures MUST live in the declarative region
    --        (before 'begin').  Placing them after 'begin' causes
    --        "syntax error near 'procedure'" and every error that
    --        follows from it.
    -- ---------------------------------------------------------------

    -- ---------------------------------------------------------------
    -- Procedure: build primary header + segment header, clear payload
    --
    -- FIX B: Removed "variable i : integer" -- for-loop indices are
    --        implicitly declared by the loop itself in VHDL.  An
    --        explicit declaration clashes and causes a compile error.
    -- ---------------------------------------------------------------
    procedure build_frame(
        constant seg_flags : in  std_logic_vector(SEG_FLAG_WIDTH-1 downto 0);
        signal   frame     : out t_frame
    ) is
        variable hdr_vec : std_logic_vector(39 downto 0);
        variable seg_vec : std_logic_vector(7 downto 0);
        variable hdr     : t_tc_header;
        variable seg_hdr : t_tc_seg_header;
    begin
        hdr.tfvn          := (others => '0');
        hdr.bypass        := '0';
        hdr.cc_flag       := '0';
        hdr.spacecraft_id := (others => '0');
        hdr.vcid          := (others => '0');
        hdr.frame_length  := std_logic_vector(
                                 to_unsigned(TC_FRAME_TOTAL_BYTES - 1,
                                             FRAME_LEN_WIDTH));
        hdr.frame_seq_nr  := (others => '0');

        hdr_vec := serialize_header(hdr);

        frame(0) <= hdr_vec(39 downto 32);
        frame(1) <= hdr_vec(31 downto 24);
        frame(2) <= hdr_vec(23 downto 16);
        frame(3) <= hdr_vec(15 downto  8);
        frame(4) <= hdr_vec( 7 downto  0);

        seg_hdr.seq_flags := seg_flags;
        seg_hdr.map_id    := DEFAULT_MAP_ID;
        seg_vec           := serialize_seg_header(seg_hdr);
        frame(TC_HEADER_BYTES) <= seg_vec;

        -- FIX B: no "variable i" declaration; loop variable is implicit
        for i in TC_HEADER_BYTES+1 to TC_FRAME_TOTAL_BYTES-1 loop
            frame(i) <= (others => '0');
        end loop;
    end procedure build_frame;

    -- ---------------------------------------------------------------
    -- Procedure: fill payload bytes with a counting pattern
    --
    -- FIX C: counter changed from "signal inout unsigned" to
    --        "variable inout unsigned".
    --   - A signal param uses <=; updates are only visible after
    --     a delta cycle, so the value can never be read back in
    --     the same loop iteration.
    --   - A variable param uses :=; updates are visible immediately,
    --     which is required for the counter to increment correctly.
    --   The caller must supply a variable (see stim_proc below).
    --
    -- FIX B (cont): no "variable i" declaration here either.
    -- ---------------------------------------------------------------
    procedure fill_payload(
        signal   frame     : inout t_frame;
        variable counter   : inout unsigned(7 downto 0);
        constant num_bytes : in    integer
    ) is
        variable base_idx : integer;
    begin
        base_idx := TC_HEADER_BYTES + TC_SEG_HDR_BYTES;
        for i in 0 to num_bytes-1 loop
            frame(base_idx + i) <= std_logic_vector(counter);
            counter := counter + 1;   -- legal: variable := on a variable param
        end loop;
    end procedure fill_payload;

begin  -- <<<< architecture body starts here; no procedures past this point

    -------------------------------------------------------------------------
    -- Clock generation
    -------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2;

    -------------------------------------------------------------------------
    -- DUT
    -------------------------------------------------------------------------
    dut : entity work.Receiver_and_Packet_Extractor
        port map (
            clk         => clk,
            rst         => rst,
            frame_in    => frame_in,
            frame_valid => frame_valid,
            pdu_data    => pdu_data,
            pdu_length  => pdu_length,
            pdu_valid   => pdu_valid,
            status      => status,
            error_flag  => error_flag
        );

    -------------------------------------------------------------------------
    -- Latch output only when a whole PDU is ready
    -------------------------------------------------------------------------
    latch_proc : process(clk)
    begin
        if rising_edge(clk) then
            if pdu_valid = '1' then
                observed_pdu_data   <= pdu_data;
                observed_pdu_length <= pdu_length;
            end if;
        end if;
    end process latch_proc;

    -------------------------------------------------------------------------
    -- Stimulus
    -------------------------------------------------------------------------
    stim_proc : process
        variable N         : integer;
        -- FIX C (cont): byte_counter is a variable here so it can be
        --   passed to fill_payload's "variable inout" parameter and
        --   updated with := inside the procedure.
        variable v_counter : unsigned(7 downto 0) := (others => '0');
    begin
        frame_in    <= (others => (others => '0'));
        frame_valid <= '0';

        -- Reset
        rst <= '1';
        wait for 5*CLK_PERIOD;
        rst <= '0';
        wait for 2*CLK_PERIOD;

        N := TC_APP_DATA_BYTES;

        ----------------------------------------------------------------
        -- Frame 1: UNSEGMENTED
        ----------------------------------------------------------------
        build_frame(SEG_FLAG_UNSEGMENTED, frame_in);
        fill_payload(frame_in, v_counter, N);

        wait until rising_edge(clk);
        frame_valid <= '1';
        wait until rising_edge(clk);
        frame_valid <= '0';

        wait for 5*CLK_PERIOD;

        ----------------------------------------------------------------
        -- Frame 2: FIRST segment
        ----------------------------------------------------------------
        build_frame(SEG_FLAG_FIRST, frame_in);
        fill_payload(frame_in, v_counter, N);

        wait until rising_edge(clk);
        frame_valid <= '1';
        wait until rising_edge(clk);
        frame_valid <= '0';

        wait for 3*CLK_PERIOD;

        ----------------------------------------------------------------
        -- Frame 3: CONTINUATION
        ----------------------------------------------------------------
        build_frame(SEG_FLAG_CONTINUATION, frame_in);
        fill_payload(frame_in, v_counter, N);

        wait until rising_edge(clk);
        frame_valid <= '1';
        wait until rising_edge(clk);
        frame_valid <= '0';

        wait for 3*CLK_PERIOD;

        ----------------------------------------------------------------
        -- Frame 4: LAST segment
        ----------------------------------------------------------------
        build_frame(SEG_FLAG_LAST, frame_in);
        fill_payload(frame_in, v_counter, N);

        wait until rising_edge(clk);
        frame_valid <= '1';
        wait until rising_edge(clk);
        frame_valid <= '0';

        -- Let DUT finish
        wait for 10*CLK_PERIOD;

        assert false report "Simulation finished" severity failure;
    end process stim_proc;

end architecture sim;