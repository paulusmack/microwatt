library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.wishbone_types.all;
use work.sim_console.all;

entity litedram_wrapper is
    generic (
	DRAM_ABITS     : positive;
	DRAM_ALINES    : positive
	);
    port(
	-- LiteDRAM generates the system clock and reset
	-- from the input clkin
	clk_in        : in std_ulogic;
	rst           : in std_ulogic;
	system_clk    : out std_ulogic;
	system_reset  : out std_ulogic;
	pll_locked    : out std_ulogic;

	-- Wishbone ports:
	wb_in         : in wishbone_master_out;
	wb_out        : out wishbone_slave_out;
	wb_csr_in     : in wishbone_master_out;
	wb_csr_out    : out wishbone_slave_out;
	wb_init_in    : in wishbone_master_out;
	wb_init_out   : out wishbone_slave_out;

	-- Misc
	init_done     : out std_ulogic;
	init_error    : out std_ulogic;

	-- DRAM wires
	ddram_a       : out std_ulogic_vector(DRAM_ALINES-1 downto 0);
	ddram_ba      : out std_ulogic_vector(2 downto 0);
	ddram_ras_n   : out std_ulogic;
	ddram_cas_n   : out std_ulogic;
	ddram_we_n    : out std_ulogic;
	ddram_cs_n    : out std_ulogic;
	ddram_dm      : out std_ulogic_vector(1 downto 0);
	ddram_dq      : inout std_ulogic_vector(15 downto 0);
	ddram_dqs_p   : out std_ulogic_vector(1 downto 0);
	ddram_dqs_n   : out std_ulogic_vector(1 downto 0);
	ddram_clk_p   : out std_ulogic;
	ddram_clk_n   : out std_ulogic;
	ddram_cke     : out std_ulogic;
	ddram_odt     : out std_ulogic;
	ddram_reset_n : out std_ulogic
	);
end entity litedram_wrapper;

architecture behaviour of litedram_wrapper is

    component litedram_core port (
	clk                    : in std_ulogic;
	rst                    : in std_ulogic;
	pll_locked             : out std_ulogic;
	ddram_a                : out std_ulogic_vector(DRAM_ALINES-1 downto 0);
	ddram_ba               : out std_ulogic_vector(2 downto 0);
	ddram_ras_n            : out std_ulogic;
	ddram_cas_n            : out std_ulogic;
	ddram_we_n             : out std_ulogic;
	ddram_cs_n             : out std_ulogic;
	ddram_dm               : out std_ulogic_vector(1 downto 0);
	ddram_dq               : inout std_ulogic_vector(15 downto 0);
	ddram_dqs_p            : out std_ulogic_vector(1 downto 0);
	ddram_dqs_n            : out std_ulogic_vector(1 downto 0);
	ddram_clk_p            : out std_ulogic;
	ddram_clk_n            : out std_ulogic;
	ddram_cke              : out std_ulogic;
	ddram_odt              : out std_ulogic;
	ddram_reset_n          : out std_ulogic;
	init_done              : out std_ulogic;
	init_error             : out std_ulogic;
	user_clk               : out std_ulogic;
	user_rst               : out std_ulogic;
	csr_port0_adr          : in std_ulogic_vector(13 downto 0);
	csr_port0_we           : in std_ulogic;
	csr_port0_dat_w        : in std_ulogic_vector(7 downto 0);
	csr_port0_dat_r        : out std_ulogic_vector(7 downto 0);
	user_port0_cmd_valid   : in std_ulogic;
	user_port0_cmd_ready   : out std_ulogic;
	user_port0_cmd_we      : in std_ulogic;
	user_port0_cmd_addr    : in std_ulogic_vector(DRAM_ABITS-1 downto 0);
	user_port0_wdata_valid : in std_ulogic;
	user_port0_wdata_ready : out std_ulogic;
	user_port0_wdata_we    : in std_ulogic_vector(15 downto 0);
	user_port0_wdata_data  : in std_ulogic_vector(127 downto 0);
	user_port0_rdata_valid : out std_ulogic;
	user_port0_rdata_ready : in std_ulogic;
	user_port0_rdata_data  : out std_ulogic_vector(127 downto 0)
	);
    end component;
    
    signal user_port0_cmd_valid		: std_ulogic;
    signal user_port0_cmd_ready		: std_ulogic;
    signal user_port0_cmd_we		: std_ulogic;
    signal user_port0_cmd_addr		: std_ulogic_vector(DRAM_ABITS-1 downto 0);
    signal user_port0_wdata_valid	: std_ulogic;
    signal user_port0_wdata_ready	: std_ulogic;
    signal user_port0_wdata_we		: std_ulogic_vector(15 downto 0);
    signal user_port0_wdata_data	: std_ulogic_vector(127 downto 0);
    signal user_port0_rdata_valid	: std_ulogic;
    signal user_port0_rdata_ready	: std_ulogic;
    signal user_port0_rdata_data	: std_ulogic_vector(127 downto 0);

    signal ad3                          : std_ulogic;

    signal csr_port0_adr                : std_ulogic_vector(13 downto 0);
    signal csr_port0_we                 : std_ulogic;
    signal csr_port0_dat_w              : std_ulogic_vector(7 downto 0);
    signal csr_port0_dat_r              : std_ulogic_vector(7 downto 0);
    signal csr_port_read_comb           : std_ulogic_vector(63 downto 0);
    signal csr_valid	                : std_ulogic;
    signal csr_write_valid	        : std_ulogic;

    type state_t is (CMD, MWRITE, MREAD);
    signal state : state_t;

    constant INIT_RAM_SIZE : integer := 16384;
    constant INIT_RAM_ABITS :integer := 14;
    constant INIT_RAM_FILE : string := "sdram_init.hex";

    type ram_t is array(0 to (INIT_RAM_SIZE / 8) - 1) of std_logic_vector(63 downto 0);

    impure function init_load_ram(name : string) return ram_t is
	file ram_file : text open read_mode is name;
	variable temp_word : std_logic_vector(63 downto 0);
	variable temp_ram : ram_t := (others => (others => '0'));
	variable ram_line : line;
    begin
	for i in 0 to (INIT_RAM_SIZE/8)-1 loop
	    exit when endfile(ram_file);
	    readline(ram_file, ram_line);
	    hread(ram_line, temp_word);
	    temp_ram(i) := temp_word;
	end loop;
	return temp_ram;
    end function;

    signal init_ram : ram_t := init_load_ram(INIT_RAM_FILE);

    attribute ram_style : string;
    attribute ram_style of init_ram: signal is "block";

begin

    -- BRAM Memory slave
    -- TODO: Fix all those vivado warnings
    init_ram_0: process(system_clk)
	variable adr : integer;
    begin
	if rising_edge(system_clk) then
	    wb_init_out.ack <= '0';
	    if (wb_init_in.cyc and wb_init_in.stb) = '1' then
		adr := to_integer((unsigned(wb_init_in.adr(INIT_RAM_ABITS-1 downto 3))));
		if wb_init_in.we = '0' then
		    wb_init_out.dat <= init_ram(adr);
		else
		    for i in 0 to 7 loop
			if wb_init_in.sel(i) = '1' then
			    init_ram(adr)(((i + 1) * 8) - 1 downto i * 8) <=
				wb_init_in.dat(((i + 1) * 8) - 1 downto i * 8);
			end if;
		    end loop;
		end if;
		wb_init_out.ack <= not wb_init_out.ack;
	    end if;
	end if;	
    end process;

    -- DRAM CSR interface signals. We only support access to the bottom byte
    -- TODO: Add a latch cycle to improve timing ?
    csr_valid <= wb_csr_in.cyc and wb_csr_in.stb;
    csr_write_valid <= wb_csr_in.we and wb_csr_in.sel(0);
    csr_port0_adr <= wb_csr_in.adr(15 downto 3) & '0';
    csr_port0_dat_w <= wb_csr_in.dat(7 downto 0);
    csr_port0_we <= csr_valid and csr_write_valid and not wb_csr_out.ack;
    wb_csr_out.dat <= x"00000000000000" & csr_port0_dat_r;

    -- CSR ACK machine
    csr: process(system_clk)
    begin
	if rising_edge(system_clk) then
	    if system_reset = '1' then
		wb_csr_out.ack <= '0';
	    else
		if csr_valid = '1' and wb_csr_out.ack = '0' then
		    wb_csr_out.ack <= '1';
		else
		    wb_csr_out.ack <= '0';
		end if;
	    end if;
	end if;
    end process;

   -- Address bit 3 selects the top or bottom half of the data
    -- bus (64-bit wishbone vs. 128-bit DRAM interface)
    --
    ad3 <= wb_in.adr(3);

    -- DRAM data interface signals
    user_port0_cmd_valid <= (wb_in.cyc and wb_in.stb) when state = CMD else '0';
    user_port0_cmd_we <= wb_in.we when state = CMD else '0';
    user_port0_wdata_valid <= '1' when state = MWRITE else '0';
    user_port0_rdata_ready <= '1' when state = MREAD else '0';
    user_port0_cmd_addr <= wb_in.adr(DRAM_ABITS+3 downto 4);
    user_port0_wdata_data <= wb_in.dat & wb_in.dat;
    user_port0_wdata_we <= wb_in.sel & "00000000" when ad3 = '1' else
			   "00000000" & wb_in.sel;

    -- DRAM Wishbone out ACK signals
    wb_out.ack <= user_port0_wdata_ready when state = MWRITE else
		  user_port0_rdata_valid when state = MREAD else '0';
    wb_out.dat <= user_port0_rdata_data(127 downto 64) when ad3 = '1' else
		  user_port0_rdata_data(63 downto 0);

    -- State machine
    sm: process(system_clk)
    begin
	
	if rising_edge(system_clk) then
	    if system_reset = '1' then
		state <= CMD;
	    else
		case state is
		when CMD =>
		    if (user_port0_cmd_ready and
			user_port0_cmd_valid) = '1' then
			state <= MWRITE when wb_in.we = '1' else MREAD;
		    end if;
		when MWRITE =>
		    if user_port0_wdata_ready = '1' then
			state <= CMD;
		    end if;
		when MREAD =>
		    if user_port0_rdata_valid = '1' then
			state <= CMD;
		    end if;
		end case;
	    end if;
	end if;
    end process;

    litedram: litedram_core
	port map(
	    clk => clk_in,
	    rst => rst,
	    pll_locked => pll_locked,
	    ddram_a => ddram_a,
	    ddram_ba => ddram_ba,
	    ddram_ras_n => ddram_ras_n,
	    ddram_cas_n => ddram_cas_n,
	    ddram_we_n => ddram_we_n,
	    ddram_cs_n => ddram_cs_n,
	    ddram_dm => ddram_dm,
	    ddram_dq => ddram_dq,
	    ddram_dqs_p => ddram_dqs_p,
	    ddram_dqs_n => ddram_dqs_n,
	    ddram_clk_p => ddram_clk_p,
	    ddram_clk_n => ddram_clk_n,
	    ddram_cke => ddram_cke,
	    ddram_odt => ddram_odt,
	    ddram_reset_n => ddram_reset_n,
	    init_done => init_done,
	    init_error => init_error,
	    user_clk => system_clk,
	    user_rst => system_reset,
	    csr_port0_adr => csr_port0_adr,
	    csr_port0_we => csr_port0_we,
	    csr_port0_dat_w => csr_port0_dat_w,
	    csr_port0_dat_r => csr_port0_dat_r,
	    user_port0_cmd_valid => user_port0_cmd_valid,
	    user_port0_cmd_ready => user_port0_cmd_ready,
	    user_port0_cmd_we => user_port0_cmd_we,
	    user_port0_cmd_addr => user_port0_cmd_addr,
	    user_port0_wdata_valid => user_port0_wdata_valid,
	    user_port0_wdata_ready => user_port0_wdata_ready,
	    user_port0_wdata_we => user_port0_wdata_we,
	    user_port0_wdata_data => user_port0_wdata_data,
	    user_port0_rdata_valid => user_port0_rdata_valid,
	    user_port0_rdata_ready => user_port0_rdata_ready,
	    user_port0_rdata_data => user_port0_rdata_data
	    );

end architecture behaviour;
