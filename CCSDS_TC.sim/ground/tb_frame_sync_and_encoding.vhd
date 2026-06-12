-- =============================================================================
-- tb_frame_sync_and_encoding.vhd
-- Testbench for frame_sync_and_encoding
-- Compatible: Vivado xsim (VHDL-93 / no VHDL-2008 constructs)
--
-- Fixes vs previous version:
--   - Replaced to_hstring() with custom slv_to_hstr() (VHDL-93 compatible)
--   - Replaced inline "x when cond else y" in procedure args with if/else
--   - Removed any other VHDL-2008-only constructs
--
-- Test cases:
--   TC1 - Single-byte payload, no back-pressure
--   TC2 - Multi-byte payload (8 bytes), no back-pressure
--   TC3 - Downstream back-pressure mid-stream
--   TC4 - Upstream back-pressure mid-stream
--   TC5 - Back-to-back data units
--   TC6 - Reset during active transfer
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.ccsds_types_pkg.all;
use work.tc_frame_pkg.all;

entity tb_frame_sync_and_encoding is
end entity tb_frame_sync_and_encoding;

architecture sim of tb_frame_sync_and_encoding is

    constant CLK_PERIOD : time := 10 ns;

    signal clk     : std_logic := '0';
    signal rst     : std_logic := '1';

    signal i_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal i_valid : std_logic := '0';
    signal o_ready : std_logic;
    signal i_last  : std_logic := '0';

    signal o_data  : std_logic_vector(7 downto 0);
    signal o_valid : std_logic;
    signal i_ready : std_logic := '1';
    signal o_last  : std_logic;

    shared variable pass_count : integer := 0;
    shared variable fail_count : integer := 0;

    -- =========================================================================
    -- Helper: convert std_logic_vector to hex string (VHDL-93 compatible)
    -- =========================================================================
    function slv_to_hstr(slv : std_logic_vector) return string is
        constant HEX_CHARS : string(1 to 16) := "0123456789ABCDEF";
        variable padded    : std_logic_vector(((slv'length + 3) / 4) * 4 - 1 downto 0)
                             := (others => '0');
        variable nibble    : std_logic_vector(3 downto 0);
        variable result    : string(1 to (slv'length + 3) / 4);
        variable idx       : integer;
    begin
        padded(slv'length - 1 downto 0) := slv;
        for i in result'range loop
            idx    := result'length - i;
            nibble := padded(idx * 4 + 3 downto idx * 4);
            result(i) := HEX_CHARS(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function slv_to_hstr;

    -- =========================================================================
    -- Procedures
    -- =========================================================================

    procedure apply_reset(
        signal rst : out std_logic;
        signal clk : in  std_logic;
        cycles     : in  integer
    ) is
    begin
        rst <= '1';
        for i in 1 to cycles loop
            wait until rising_edge(clk);
        end loop;
        wait for 1 ns;
        rst <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
    end procedure;

    -- Send one byte; waits for o_ready handshake
    procedure send_byte(
        signal clk     : in  std_logic;
        signal i_data  : out std_logic_vector(7 downto 0);
        signal i_valid : out std_logic;
        signal i_last  : out std_logic;
        signal o_ready : in  std_logic;
        data           : in  std_logic_vector(7 downto 0);
        is_last        : in  boolean
    ) is
    begin
        i_data  <= data;
        i_valid <= '1';
        if is_last then
            i_last <= '1';
        else
            i_last <= '0';
        end if;

        loop
            wait until rising_edge(clk);
            exit when o_ready = '1';
        end loop;

        wait for 1 ns;
        i_valid <= '0';
        i_last  <= '0';
        i_data  <= (others => '0');
    end procedure;

    -- Receive one byte; waits for o_valid handshake
    procedure recv_byte(
        signal clk     : in  std_logic;
        signal o_data  : in  std_logic_vector(7 downto 0);
        signal o_valid : in  std_logic;
        signal o_last  : in  std_logic;
        signal i_ready : out std_logic;
        variable data_out : out std_logic_vector(7 downto 0);
        variable last_out : out std_logic
    ) is
    begin
        i_ready <= '1';
        loop
            wait until rising_edge(clk);
            exit when o_valid = '1';
        end loop;
        wait for 1 ns;
        data_out := o_data;
        last_out := o_last;
    end procedure;

    -- Assert and report a check
    procedure check(
        condition : in boolean;
        msg       : in string
    ) is
    begin
        if condition then
            pass_count := pass_count + 1;
            report "[PASS] " & msg severity note;
        else
            fail_count := fail_count + 1;
            report "[FAIL] " & msg severity error;
        end if;
    end procedure;

    -- Receive and verify all ASM_BYTES bytes against ASM_PATTERN
    procedure check_asm(
        signal clk     : in  std_logic;
        signal o_data  : in  std_logic_vector(7 downto 0);
        signal o_valid : in  std_logic;
        signal o_last  : in  std_logic;
        signal i_ready : out std_logic;
        tc_id          : in  string
    ) is
        variable rx_byte : std_logic_vector(7 downto 0);
        variable rx_last : std_logic;
    begin
        for idx in 0 to ASM_BYTES - 1 loop
            recv_byte(clk, o_data, o_valid, o_last, i_ready,
                      rx_byte, rx_last);
            check(rx_byte = ASM_PATTERN(idx),
                  tc_id & " ASM[" & integer'image(idx) & "]"
                  & " got=0x" & slv_to_hstr(rx_byte)
                  & " exp=0x" & slv_to_hstr(ASM_PATTERN(idx)));
            check(rx_last = '0',
                  tc_id & " o_last='0' on ASM byte "
                  & integer'image(idx));
        end loop;
    end procedure;

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.frame_sync_and_encoding
        port map (
            clk     => clk,
            rst     => rst,
            i_data  => i_data,
            i_valid => i_valid,
            o_ready => o_ready,
            i_last  => i_last,
            o_data  => o_data,
            o_valid => o_valid,
            i_ready => i_ready,
            o_last  => o_last
        );

    -- =========================================================================
    p_stim : process
        variable rx_byte : std_logic_vector(7 downto 0);
        variable rx_last : std_logic;

        type t_payload is array (natural range <>) of std_logic_vector(7 downto 0);

        constant PAYLOAD_A : t_payload(0 to 7) := (
            x"A0", x"A1", x"A2", x"A3",
            x"A4", x"A5", x"A6", x"A7");

        constant PAYLOAD_B : t_payload(0 to 4) := (
            x"B0", x"B1", x"B2", x"B3", x"B4");

    begin

        apply_reset(rst, clk, 4);
        i_ready <= '1';
        wait for CLK_PERIOD * 2;

        -- =====================================================================
        -- TC1: Single-byte payload, no back-pressure
        -- =====================================================================
        report "--- TC1: single byte, no back-pressure" severity note;

        send_byte(clk, i_data, i_valid, i_last, o_ready, x"DE", true);

        check_asm(clk, o_data, o_valid, o_last, i_ready, "TC1");

        recv_byte(clk, o_data, o_valid, o_last, i_ready, rx_byte, rx_last);
        check(rx_byte = x"DE",
              "TC1 payload=0x" & slv_to_hstr(rx_byte) & " exp=0xDE");
        check(rx_last = '1', "TC1 o_last='1' on last byte");

        wait for CLK_PERIOD * 4;
        check(o_valid = '0', "TC1 no extra bytes emitted");

        -- =====================================================================
        -- TC2: 8-byte payload, no back-pressure
        -- =====================================================================
        report "--- TC2: 8 bytes, no back-pressure" severity note;

        for idx in PAYLOAD_A'range loop
            if idx = PAYLOAD_A'high then
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_A(idx), true);
            else
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_A(idx), false);
            end if;
        end loop;

        check_asm(clk, o_data, o_valid, o_last, i_ready, "TC2");

        for idx in PAYLOAD_A'range loop
            recv_byte(clk, o_data, o_valid, o_last, i_ready, rx_byte, rx_last);
            check(rx_byte = PAYLOAD_A(idx),
                  "TC2 payload[" & integer'image(idx) & "]"
                  & " got=0x" & slv_to_hstr(rx_byte)
                  & " exp=0x" & slv_to_hstr(PAYLOAD_A(idx)));
            if idx = PAYLOAD_A'high then
                check(rx_last = '1',
                      "TC2 o_last='1' on byte " & integer'image(idx));
            else
                check(rx_last = '0',
                      "TC2 o_last='0' on byte " & integer'image(idx));
            end if;
        end loop;

        wait for CLK_PERIOD * 4;
        check(o_valid = '0', "TC2 no extra bytes emitted");

        -- =====================================================================
        -- TC3: Downstream back-pressure after 2nd payload byte
        -- =====================================================================
        report "--- TC3: downstream back-pressure mid-stream" severity note;

        for idx in PAYLOAD_A'range loop
            if idx = PAYLOAD_A'high then
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_A(idx), true);
            else
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_A(idx), false);
            end if;
        end loop;

        check_asm(clk, o_data, o_valid, o_last, i_ready, "TC3");

        for idx in PAYLOAD_A'range loop
            if idx = 2 then
                i_ready <= '0';
                wait for CLK_PERIOD * 3;
                check(o_valid = '1',
                      "TC3 o_valid stable during back-pressure");
                check(o_data = PAYLOAD_A(idx),
                      "TC3 o_data stable=0x" & slv_to_hstr(o_data)
                      & " exp=0x" & slv_to_hstr(PAYLOAD_A(idx)));
                i_ready <= '1';
                wait until rising_edge(clk);
                wait for 1 ns;
            end if;

            recv_byte(clk, o_data, o_valid, o_last, i_ready, rx_byte, rx_last);
            check(rx_byte = PAYLOAD_A(idx),
                  "TC3 payload[" & integer'image(idx) & "]"
                  & " got=0x" & slv_to_hstr(rx_byte)
                  & " exp=0x" & slv_to_hstr(PAYLOAD_A(idx)));
            if idx = PAYLOAD_A'high then
                check(rx_last = '1', "TC3 o_last='1' on final byte");
            end if;
        end loop;

        wait for CLK_PERIOD * 4;
        check(o_valid = '0', "TC3 no extra bytes emitted");

        -- =====================================================================
        -- TC4: Upstream back-pressure after byte 3
        -- =====================================================================
        report "--- TC4: upstream back-pressure mid-stream" severity note;

        i_ready <= '1';

        for idx in PAYLOAD_A'range loop
            if idx = PAYLOAD_A'high then
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_A(idx), true);
            else
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_A(idx), false);
            end if;

            if idx = 3 then
                wait for CLK_PERIOD * 5;
            end if;
        end loop;

        check_asm(clk, o_data, o_valid, o_last, i_ready, "TC4");

        for idx in PAYLOAD_A'range loop
            recv_byte(clk, o_data, o_valid, o_last, i_ready, rx_byte, rx_last);
            check(rx_byte = PAYLOAD_A(idx),
                  "TC4 payload[" & integer'image(idx) & "]"
                  & " got=0x" & slv_to_hstr(rx_byte)
                  & " exp=0x" & slv_to_hstr(PAYLOAD_A(idx)));
            if idx = PAYLOAD_A'high then
                check(rx_last = '1', "TC4 o_last='1' on final byte");
            end if;
        end loop;

        wait for CLK_PERIOD * 4;
        check(o_valid = '0', "TC4 no extra bytes emitted");

        -- =====================================================================
        -- TC5: Back-to-back data units
        -- =====================================================================
        report "--- TC5: back-to-back data units" severity note;

        i_ready <= '1';

        for idx in PAYLOAD_A'range loop
            if idx = PAYLOAD_A'high then
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_A(idx), true);
            else
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_A(idx), false);
            end if;
        end loop;

        for idx in PAYLOAD_B'range loop
            if idx = PAYLOAD_B'high then
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_B(idx), true);
            else
                send_byte(clk, i_data, i_valid, i_last, o_ready,
                          PAYLOAD_B(idx), false);
            end if;
        end loop;

        check_asm(clk, o_data, o_valid, o_last, i_ready, "TC5-A");
        for idx in PAYLOAD_A'range loop
            recv_byte(clk, o_data, o_valid, o_last, i_ready, rx_byte, rx_last);
            check(rx_byte = PAYLOAD_A(idx),
                  "TC5-A payload[" & integer'image(idx) & "]"
                  & " got=0x" & slv_to_hstr(rx_byte)
                  & " exp=0x" & slv_to_hstr(PAYLOAD_A(idx)));
            if idx = PAYLOAD_A'high then
                check(rx_last = '1', "TC5-A o_last='1' on final byte");
            end if;
        end loop;

        check_asm(clk, o_data, o_valid, o_last, i_ready, "TC5-B");
        for idx in PAYLOAD_B'range loop
            recv_byte(clk, o_data, o_valid, o_last, i_ready, rx_byte, rx_last);
            check(rx_byte = PAYLOAD_B(idx),
                  "TC5-B payload[" & integer'image(idx) & "]"
                  & " got=0x" & slv_to_hstr(rx_byte)
                  & " exp=0x" & slv_to_hstr(PAYLOAD_B(idx)));
            if idx = PAYLOAD_B'high then
                check(rx_last = '1', "TC5-B o_last='1' on final byte");
            end if;
        end loop;

        wait for CLK_PERIOD * 4;
        check(o_valid = '0', "TC5 no extra bytes emitted");

        -- =====================================================================
        -- TC6: Reset during active transfer
        -- =====================================================================
        report "--- TC6: reset during active transfer" severity note;

        i_ready <= '1';

        send_byte(clk, i_data, i_valid, i_last, o_ready, x"FF", true);

        wait for CLK_PERIOD * 2;
        rst <= '1';
        wait for CLK_PERIOD * 2;
        rst <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;

        check(o_valid = '0', "TC6 o_valid='0' after reset");
        check(o_last  = '0', "TC6 o_last='0' after reset");

        send_byte(clk, i_data, i_valid, i_last, o_ready, x"C0", true);

        check_asm(clk, o_data, o_valid, o_last, i_ready, "TC6-post-reset");

        recv_byte(clk, o_data, o_valid, o_last, i_ready, rx_byte, rx_last);
        check(rx_byte = x"C0",
              "TC6 post-reset payload=0x" & slv_to_hstr(rx_byte) & " exp=0xC0");
        check(rx_last = '1', "TC6 post-reset o_last='1'");

        wait for CLK_PERIOD * 4;

        -- =====================================================================
        -- Summary
        -- =====================================================================
        report "========================================" severity note;
        if fail_count = 0 then
            report "ALL " & integer'image(pass_count)
                   & " CHECKS PASSED" severity note;
        else
            report integer'image(fail_count) & " FAILED / "
                   & integer'image(pass_count + fail_count)
                   & " TOTAL" severity failure;
        end if;
        report "========================================" severity note;

        -- Let DUT finish
        wait for 10*CLK_PERIOD;

        assert false report "Simulation finished" severity failure;
        
    end process p_stim;

end architecture sim;