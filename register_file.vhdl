library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.common.all;

entity register_file is
    generic (
        SIM : boolean := false;
        HAS_FPU : boolean := true;
        HAS_VECVSX : boolean := true;
        -- Non-zero to enable log data collection
        LOG_LENGTH : natural := 0
        );
    port(
        clk           : in std_logic;
        stall         : in std_ulogic;

        d1_in         : in Decode1ToRegisterFileType;
        d_in          : in Decode2ToRegisterFileType;
        d_out         : out RegisterFileToDecode2Type;

        w_in          : in WritebackToRegisterFileType;

        dbg_gpr_req   : in std_ulogic;
        dbg_gpr_ack   : out std_ulogic;
        dbg_gpr_addr  : in gspr_index_t;
        dbg_gpr_data  : out std_ulogic_vector(63 downto 0);
        dbg_gpr_ldata : out std_ulogic_vector(63 downto 0);

        -- debug
        sim_dump      : in std_ulogic;
        sim_dump_done : out std_ulogic;

        log_out       : out std_ulogic_vector(71 downto 0)
        );
end entity register_file;

architecture behaviour of register_file is

    function regfilesize return integer is
    begin
        if HAS_VECVSX then
            return 128;
        elsif HAS_FPU then
            return 64;
        else
            return 32;
        end if;
    end;

    -- Make it obvious that we only want 64 GSPRs for a no-vector implementation
    -- (in that case the FPRs are 32-63 not 64-95), or 32 if we have no FPU.
    function regfileaddr(index : std_ulogic_vector) return std_ulogic_vector is
        variable addr : std_ulogic_vector(6 downto 0);
    begin
        addr := index(6 downto 0);
        if not HAS_VECVSX then
            addr(5) := addr(6);
            addr(6) := '0';
            if not HAS_FPU then
                addr(5) := '0';
            end if;
        end if;
        return addr;
    end;

    -- GPRs, FPRs, high halves of VRs
    type regfile is array(0 to regfilesize - 1) of std_ulogic_vector(63 downto 0);
    signal registers : regfile := (others => (others => '0'));

    -- Low halves of VSRs
    type reglofile is array(0 to 63) of std_ulogic_vector(63 downto 0);
    signal lo_registers : reglofile := (others => (others => '0'));

    signal dbg_data : std_ulogic_vector(63 downto 0);
    signal dbg_lo_data : std_ulogic_vector(63 downto 0);
    signal dbg_ack : std_ulogic;
    signal dbg_gpr_done : std_ulogic;
    signal addr_1_reg : gspr_index_t;
    signal addr_2_reg : gspr_index_t;
    signal addr_3_reg : gspr_index_t;
    signal fwd_1 : std_ulogic;
    signal fwd_2 : std_ulogic;
    signal fwd_3 : std_ulogic;
    signal data_1 : std_ulogic_vector(63 downto 0);
    signal data_2 : std_ulogic_vector(63 downto 0);
    signal data_3 : std_ulogic_vector(63 downto 0);
    signal prev_write_data : std_ulogic_vector(63 downto 0);
    signal lo_data_1 : std_ulogic_vector(63 downto 0);
    signal lo_data_2 : std_ulogic_vector(63 downto 0);
    signal lo_data_3 : std_ulogic_vector(63 downto 0);
    signal lo_prev_write_data : std_ulogic_vector(63 downto 0);
    signal alt_data_1 : std_ulogic_vector(63 downto 0);
    signal alt_data_2 : std_ulogic_vector(63 downto 0);
    signal alt_data_3 : std_ulogic_vector(63 downto 0);
    signal lo_alt_data_1 : std_ulogic_vector(63 downto 0);
    signal lo_alt_data_2 : std_ulogic_vector(63 downto 0);
    signal lo_alt_data_3 : std_ulogic_vector(63 downto 0);
    signal stall_r : std_ulogic;

begin
    -- synchronous reads and writes
    register_write_0: process(clk)
        variable a_addr, b_addr, c_addr : gspr_index_t;
        variable w_addr : gspr_index_t;
    begin
        if rising_edge(clk) then
            w_addr := regfileaddr(w_in.write_reg);
            a_addr := regfileaddr(d1_in.reg_1_addr);
            b_addr := regfileaddr(d1_in.reg_2_addr);
            c_addr := regfileaddr(d1_in.reg_3_addr);

            -- record current read data in case of stall
            alt_data_1 <= d_out.read1_data;
            alt_data_2 <= d_out.read2_data;
            alt_data_3 <= d_out.read3_data;
            lo_alt_data_1 <= d_out.lovr1_data;
            lo_alt_data_2 <= d_out.lovr2_data;
            lo_alt_data_3 <= d_out.lovr3_data;

            stall_r <= stall;

            prev_write_data <= w_in.write_data;
            lo_prev_write_data <= w_in.lovrw_data;

            fwd_1 <= '0';
            fwd_2 <= '0';
            fwd_3 <= '0';
            if w_in.write_enable = '1' then
                if (stall = '0' and w_addr = a_addr) or (stall = '1' and w_addr = addr_1_reg) then
                    fwd_1 <= '1';
                end if;
                if (stall = '0' and w_addr = b_addr) or (stall = '1' and w_addr = addr_2_reg) then
                    fwd_2 <= '1';
                end if;
                if (stall = '0' and w_addr = c_addr) or (stall = '1' and w_addr = addr_3_reg) then
                    fwd_3 <= '1';
                end if;
            end if;

            if stall = '0' then
                addr_1_reg <= a_addr;
                addr_2_reg <= b_addr;
                addr_3_reg <= c_addr;
            end if;

            -- Do debug reads to GPRs and FPRs using the B port when it is not in use
            if dbg_gpr_req = '1' then
                if stall = '1' or d1_in.read_2_enable = '0' then
                    b_addr := regfileaddr(dbg_gpr_addr);
                    dbg_gpr_done <= '1';
                end if;
            else
                dbg_gpr_done <= '0';
            end if;

	    if is_X(a_addr) then
		data_1 <= (others => 'X');
                lo_data_1 <= (others => 'X');
	    else
		data_1 <= registers(to_integer(unsigned(a_addr)));
		lo_data_1 <= lo_registers(to_integer(unsigned(a_addr(5 downto 0))));
	    end if;
	    if is_X(b_addr) then
		data_2 <= (others => 'X');
                lo_data_2 <= (others => 'X');
	    else
		data_2 <= registers(to_integer(unsigned(b_addr)));
		lo_data_2 <= lo_registers(to_integer(unsigned(b_addr(5 downto 0))));
	    end if;
	    if is_X(c_addr) then
		data_3 <= (others => 'X');
                lo_data_3 <= (others => 'X');
	    else
		data_3 <= registers(to_integer(unsigned(c_addr)));
		lo_data_3 <= lo_registers(to_integer(unsigned(c_addr(5 downto 0))));
	    end if;

            if w_in.write_enable = '1' then
                if HAS_VECVSX and w_addr(6) = '1' then
                    report "Writing VSR " & to_hstring(w_addr(5 downto 0)) & " " &
                        to_hstring(w_in.write_data) & "_" & to_hstring(w_in.lovrw_data);
                elsif not HAS_VECVSX and HAS_FPU and w_addr(5) = '1' then
                    report "Writing FPR " & to_hstring(w_addr(4 downto 0)) & " " & to_hstring(w_in.write_data);
                else
                    report "Writing GPR " & to_hstring(w_addr) & " " & to_hstring(w_in.write_data);
                end if;
                assert not(is_x(w_in.write_data)) and not(is_x(w_in.write_reg)) severity failure;
                registers(to_integer(unsigned(w_addr))) <= w_in.write_data;
                if HAS_VECVSX and w_addr(6) = '1' then
                    lo_registers(to_integer(unsigned(w_addr(5 downto 0)))) <= w_in.lovrw_data;
                end if;
            end if;

        end if;
    end process register_write_0;

    -- asynchronous forwarding of write data
    register_read_0: process(all)
        variable out_data_1 : std_ulogic_vector(63 downto 0);
        variable out_data_2 : std_ulogic_vector(63 downto 0);
        variable out_data_3 : std_ulogic_vector(63 downto 0);
        variable lo_out_data_1 : std_ulogic_vector(63 downto 0);
        variable lo_out_data_2 : std_ulogic_vector(63 downto 0);
        variable lo_out_data_3 : std_ulogic_vector(63 downto 0);
    begin
        out_data_1 := data_1;
        out_data_2 := data_2;
        out_data_3 := data_3;
        lo_out_data_1 := lo_data_1;
        lo_out_data_2 := lo_data_2;
        lo_out_data_3 := lo_data_3;
        if fwd_1 = '1' then
            out_data_1 := prev_write_data;
            lo_out_data_1 := lo_prev_write_data;
        elsif stall_r = '1' then
            out_data_1 := alt_data_1;
            lo_out_data_1 := lo_alt_data_1;
        end if;
        if fwd_2 = '1' then
            out_data_2 := prev_write_data;
            lo_out_data_2 := lo_prev_write_data;
        elsif stall_r = '1' then
            out_data_2 := alt_data_2;
            lo_out_data_2 := lo_alt_data_2;
        end if;
        if fwd_3 = '1' then
            out_data_3 := prev_write_data;
            lo_out_data_3 := lo_prev_write_data;
        elsif stall_r = '1' then
            out_data_3 := alt_data_3;
            lo_out_data_3 := lo_alt_data_3;
        end if;

        if d_in.read1_enable = '1' then
            report "Reading GPR " & to_hstring(addr_1_reg) & " " & to_hstring(out_data_1);
        end if;
        if d_in.read2_enable = '1' then
            report "Reading GPR " & to_hstring(addr_2_reg) & " " & to_hstring(out_data_2);
        end if;
        if d_in.read3_enable = '1' then
            report "Reading GPR " & to_hstring(addr_3_reg) & " " & to_hstring(out_data_3);
        end if;

        d_out.read1_data <= out_data_1;
        d_out.read2_data <= out_data_2;
        d_out.read3_data <= out_data_3;
        if HAS_VECVSX then
            d_out.lovr1_data <= lo_out_data_1;
            d_out.lovr2_data <= lo_out_data_2;
            d_out.lovr3_data <= lo_out_data_3;
        else
            d_out.lovr1_data <= (others => '0');
            d_out.lovr2_data <= (others => '0');
            d_out.lovr3_data <= (others => '0');
        end if;
    end process register_read_0;

    -- Latch read data and ack if dbg read requested and B port not busy
    dbg_register_read: process(clk)
    begin
        if rising_edge(clk) then
            if dbg_gpr_req = '1' then
                if dbg_ack = '0' and dbg_gpr_done = '1' then
                    dbg_data <= data_2;
                    dbg_lo_data <= lo_data_2;
                    dbg_ack <= '1';
                end if;
            else
                dbg_ack <= '0';
            end if;
        end if;
    end process;

    dbg_gpr_ack <= dbg_ack;
    dbg_gpr_data <= dbg_data;
    dbg_gpr_ldata <= dbg_lo_data;

    -- Dump registers if core terminates
    sim_dump_test: if SIM generate
        dump_registers: process(all)
        begin
            if sim_dump = '1' then
                loop_0: for i in 0 to 31 loop
                    report "GPR" & integer'image(i) & " " & to_hstring(registers(i));
                end loop loop_0;
                sim_dump_done <= '1';
            else
                sim_dump_done <= '0';
            end if;
        end process;
    end generate;

    -- Keep GHDL synthesis happy
    sim_dump_test_synth: if not SIM generate
        sim_dump_done <= '0';
    end generate;

    rf_log: if LOG_LENGTH > 0 generate
        signal log_data : std_ulogic_vector(71 downto 0);
    begin
        reg_log: process(clk)
        begin
            if rising_edge(clk) then
                log_data <= w_in.write_data &
                            w_in.write_enable &
                            w_in.write_reg;
            end if;
        end process;
        log_out <= log_data;
    end generate;

end architecture behaviour;
