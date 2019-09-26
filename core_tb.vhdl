library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.common.all;
use work.wishbone_types.all;

entity core_tb is
end core_tb;

architecture behave of core_tb is
	signal clk, rst: std_logic;

	-- testbench signals
	constant clk_period : time := 10 ns;

        -- Dummy DRAM
	signal wb_dram_in : wishbone_master_out;
        signal wb_dram_out : wishbone_slave_out;
	signal wb_csr_in : wishbone_master_out;
        signal wb_csr_out : wishbone_slave_out;
	signal wb_bios_in : wishbone_master_out;
        signal wb_bios_out : wishbone_slave_out;
begin

    soc0: entity work.soc
	generic map(
	    SIM => true,
	    MEMORY_SIZE => 524288,
	    RAM_INIT_FILE => "simple_ram_behavioural.bin",
	    RESET_LOW => false,
	    CLK_FREQ => 100000000
	    )
	port map(
	    rst           => rst,
	    system_clk    => clk,
	    uart0_rxd     => '0',
	    uart0_txd     => open,
	    wb_dram_in    => wb_dram_in,
	    wb_dram_out   => wb_dram_out,
	    wb_csr_in     => wb_csr_in,
	    wb_csr_out    => wb_csr_out,
	    wb_bios_in    => wb_bios_in,
	    wb_bios_out   => wb_bios_out,
	    alt_reset     => '0'
	    );

    clk_process: process
    begin
	clk <= '0';
	wait for clk_period/2;
	clk <= '1';
	wait for clk_period/2;
    end process;

    rst_process: process
    begin
	rst <= '1';
	wait for 10*clk_period;
	rst <= '0';
	wait;
    end process;

    jtag: entity work.sim_jtag;

    -- Dummy DRAM
    wb_dram_out.ack <= wb_dram_in.cyc and wb_dram_in.stb;
    wb_dram_out.dat <= (others => '1');
    wb_csr_out.ack <= wb_csr_in.cyc and wb_csr_in.stb;
    wb_csr_out.dat <= (others => '1');
    wb_bios_out.ack <= wb_bios_in.cyc and wb_bios_in.stb;
    wb_bios_out.dat <= (others => '1');

end;
