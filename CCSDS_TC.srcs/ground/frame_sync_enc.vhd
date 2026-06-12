-- =============================================================================
-- frame_sync_and_encoding.vhd
-- Ground Segment - TC Uplink
--
-- Sits between the TC Command Interface and Segmentation_and_Frame_Generator.
-- Responsibilities (this iteration - no encoding):
--
--   1. Accept raw TC command bytes from upstream via a valid/ready/last
--      handshake (byte-wide, AXI4-Stream slave compatible).
--   2. Prepend the CCSDS Attached Sync Marker (ASM) to each data unit.
--   3. Forward ASM + payload bytes downstream via the same handshake.
--      o_last is asserted on the last PAYLOAD byte only (never on ASM bytes).
--
-- Handshake rule (both ports):
--   Transfer occurs on rising edge when valid='1' AND ready='1'.
--   Sender holds data+valid stable until ready is seen high.
--
-- FSM states:
--   S_IDLE    - waiting for first upstream byte
--   S_ASM     - streaming ASM bytes downstream
--   S_PAYLOAD - forwarding payload bytes with zero-bubble back-to-back support
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

entity frame_sync_and_encoding is
    port (
        clk     : in  std_logic;
        rst     : in  std_logic;

        -- Upstream interface (from TC Command Interface / AXI-Stream DMA)
        i_data  : in  std_logic_vector(7 downto 0);
        i_valid : in  std_logic;
        o_ready : out std_logic;
        i_last  : in  std_logic;

        -- Downstream interface (to Segmentation_and_Frame_Generator)
        o_data  : out std_logic_vector(7 downto 0);
        o_valid : out std_logic;
        i_ready : in  std_logic;
        o_last  : out std_logic
    );
end entity frame_sync_and_encoding;

architecture rtl of frame_sync_and_encoding is

    -- =========================================================================
    -- FSM
    -- =========================================================================
    type t_state is (S_IDLE, S_ASM, S_PAYLOAD);
    signal state : t_state := S_IDLE;

    -- =========================================================================
    -- Registers
    -- =========================================================================

    -- Index into ASM_PATTERN
    signal asm_idx   : integer range 0 to ASM_BYTES - 1 := 0;

    -- One-byte look-ahead: holds the byte currently being offered downstream.
    -- Latching one cycle ahead lets us assert o_last on the correct transfer
    -- without a pipeline bubble.
    signal data_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal last_reg  : std_logic := '0';
    signal reg_valid : std_logic := '0';

    -- Registered output signals
    signal s_o_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal s_o_valid : std_logic := '0';
    signal s_o_last  : std_logic := '0';
    signal s_o_ready : std_logic := '0';

begin

    o_data  <= s_o_data;
    o_valid <= s_o_valid;
    o_last  <= s_o_last;
    o_ready <= s_o_ready;

    -- =========================================================================
    -- Main FSM process
    -- =========================================================================
    p_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state      <= S_IDLE;
                asm_idx    <= 0;
                data_reg   <= (others => '0');
                last_reg   <= '0';
                reg_valid  <= '0';
                s_o_data   <= (others => '0');
                s_o_valid  <= '0';
                s_o_last   <= '0';
                s_o_ready  <= '0';

            else
                case state is

                    -- ---------------------------------------------------------
                    -- S_IDLE: ready to accept; latch first byte then emit ASM.
                    -- ---------------------------------------------------------
                    when S_IDLE =>
                        s_o_valid  <= '0';
                        s_o_last   <= '0';
                        s_o_ready  <= '1';
                        asm_idx    <= 0;
                        reg_valid  <= '0';

                        if i_valid = '1' then
                            data_reg   <= i_data;
                            last_reg   <= i_last;
                            reg_valid  <= '1';
                            s_o_data   <= ASM_PATTERN(0);
                            s_o_valid  <= '1';
                            s_o_last   <= '0';
                            s_o_ready  <= '0';   -- stall upstream; data_reg full
                            state      <= S_ASM;
                        end if;

                    -- ---------------------------------------------------------
                    -- S_ASM: stream all ASM bytes downstream; handle back-pressure.
                    -- On the last ASM acceptance, present the latched payload byte.
                    -- ---------------------------------------------------------
                    when S_ASM =>
                        s_o_ready <= '0';   -- upstream stalled throughout ASM phase

                        if s_o_valid = '1' and i_ready = '1' then
                            if asm_idx = ASM_BYTES - 1 then
                                -- Last ASM byte accepted; start payload phase
                                s_o_data  <= data_reg;
                                s_o_valid <= '1';
                                s_o_last  <= last_reg;
                                s_o_ready <= '0';
                                asm_idx   <= 0;
                                state     <= S_PAYLOAD;
                            else
                                asm_idx   <= asm_idx + 1;
                                s_o_data  <= ASM_PATTERN(asm_idx + 1);
                                s_o_valid <= '1';
                                s_o_last  <= '0';
                            end if;
                        end if;
                        -- i_ready='0': hold outputs stable (registers retain values)

                    -- ---------------------------------------------------------
                    -- S_PAYLOAD: forward payload bytes.
                    --
                    -- When downstream accepts the current byte AND it is NOT the
                    -- last, we raise o_ready and attempt to accept the next
                    -- upstream byte in the same clock cycle (zero-bubble).
                    --
                    -- When the last byte is accepted, return to S_IDLE.
                    --
                    -- If upstream has no byte ready yet, o_valid is deasserted
                    -- and o_ready stays high until upstream delivers.
                    -- ---------------------------------------------------------
                    when S_PAYLOAD =>

                        if s_o_valid = '1' and i_ready = '1' then

                            if last_reg = '1' then
                                -- Final byte accepted; o_last was already high
                                s_o_valid <= '0';
                                s_o_last  <= '0';
                                s_o_ready <= '0';
                                reg_valid <= '0';
                                state     <= S_IDLE;

                            else
                                -- Try zero-bubble: accept next byte this cycle
                                s_o_ready <= '1';

                                if i_valid = '1' then
                                    data_reg  <= i_data;
                                    last_reg  <= i_last;
                                    s_o_data  <= i_data;
                                    s_o_valid <= '1';
                                    s_o_last  <= i_last;
                                    s_o_ready <= '0';
                                else
                                    -- Upstream not ready; stall downstream
                                    s_o_valid <= '0';
                                    s_o_last  <= '0';
                                    reg_valid <= '0';
                                    -- s_o_ready stays '1' to solicit next byte
                                end if;
                            end if;

                        elsif s_o_valid = '0' then
                            -- We were stalled waiting for upstream
                            s_o_ready <= '1';

                            if i_valid = '1' then
                                data_reg  <= i_data;
                                last_reg  <= i_last;
                                s_o_data  <= i_data;
                                s_o_valid <= '1';
                                s_o_last  <= i_last;
                                s_o_ready <= '0';
                                reg_valid <= '1';
                            end if;

                        end if;
                        -- else: i_ready='0', hold all outputs stable

                    when others =>
                        state <= S_IDLE;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;