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

        e_in          : in Execute1ToRegisterFileType;
        e_out         : out RegisterFileToExecute1Type;

        dbg_gpr_req   : in std_ulogic;
        dbg_gpr_ack   : out std_ulogic;
        dbg_gpr_addr  : in gspr_index_t;
        dbg_gpr_data  : out std_ulogic_vector(63 downto 0);

        -- debug
        sim_dump      : in std_ulogic;
        sim_dump_done : out std_ulogic;

        log_out       : out std_ulogic_vector(72 downto 0)
        );
end entity register_file;

architecture behaviour of register_file is

    function regfilesize return integer is
    begin
        if HAS_VECVSX then
            return 192;
        elsif HAS_FPU then
            return 64;
        else
            return 32;
        end if;
    end;

    function regfileaddr(r: gspr_index_t) return integer is
        variable i : std_ulogic_vector(7 downto 0);
    begin
        if HAS_VECVSX then
            i := r;
        elsif HAS_FPU then
            -- pack FPRs and GPRs contiguously
            i := "00" & r(6) & r(4 downto 0);
        else
            i := "000" & r(4 downto 0);
        end if;
        return to_integer(unsigned(i));
    end;

    type regfile is array(0 to regfilesize - 1) of std_ulogic_vector(63 downto 0);
    signal registers : regfile := (others => (others => '0'));
    signal dbg_data : std_ulogic_vector(63 downto 0);
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
    signal alt_data_1 : std_ulogic_vector(63 downto 0);
    signal alt_data_2 : std_ulogic_vector(63 downto 0);
    signal alt_data_3 : std_ulogic_vector(63 downto 0);
    signal indirect_ack : std_ulogic;

begin
    -- synchronous reads and writes
    register_write_0: process(clk)
        variable a_addr, b_addr, c_addr : gspr_index_t;
        variable w_addr : gspr_index_t;
        variable w_data : std_ulogic_vector(63 downto 0);
        variable we     : std_ulogic;
    begin
        if rising_edge(clk) then
            indirect_ack <= '0';
            dbg_gpr_done <= '0';
            we := '0';
            if w_in.write_enable = '1' then
                w_addr := w_in.write_reg;
                w_data := w_in.write_data;
                if HAS_VECVSX and w_addr(7) = '1' then
                    report "Writing VR " & to_hstring(w_addr(4 downto 0)) & "." &
                        std_ulogic'image(w_addr(5)) & " " & to_hstring(w_in.write_data);
                elsif HAS_FPU and w_addr(6) = '1' then
                    if w_addr(5) = '0' then
                        report "Writing FPR " & to_hstring(w_addr(4 downto 0)) & " " & to_hstring(w_in.write_data);
                    else
                        report "Writing VSR.lo " & to_hstring(w_addr(4 downto 0)) & " " & to_hstring(w_in.write_data);
                    end if;
                elsif w_addr(5) = '1' then
                    report "Writing alt GPR " & to_hstring(w_addr) & " " & to_hstring(w_in.write_data);
                else
                    report "Writing GPR " & to_hstring(w_addr) & " " & to_hstring(w_in.write_data);
                end if;
                assert not(is_x(w_in.write_data)) and not(is_x(w_in.write_reg)) severity failure;
                we := '1';
            else
                w_addr := e_in.reg_addr;
                w_data := e_in.write_data;
                if e_in.write_req = '1' then
                    report "Indirect write GSPR " & to_hstring(w_addr) & " to " & to_hstring(w_data);
                    we := '1';
                    indirect_ack <= '1';
                end if;
            end if;
            if we = '1' then
                registers(regfileaddr(w_addr)) <= w_data;
            end if;

            a_addr := d1_in.reg_1_addr;
            b_addr := d1_in.reg_2_addr;
            c_addr := d1_in.reg_3_addr;
            if stall = '1' then
                a_addr := addr_1_reg;
                b_addr := addr_2_reg;
                c_addr := addr_3_reg;
            else
                addr_1_reg <= a_addr;
                addr_2_reg <= b_addr;
                addr_3_reg <= c_addr;
            end if;

            -- record current read data in case of stall
            alt_data_1 <= d_out.read1_data;
            alt_data_2 <= d_out.read2_data;
            alt_data_3 <= d_out.read3_data;

            fwd_1 <= stall;
            fwd_2 <= stall;
            fwd_3 <= stall;
            if w_in.write_enable = '1' then
                if w_addr = a_addr then
                    fwd_1 <= '1';
                    alt_data_1 <= w_in.write_data;
                end if;
                if w_addr = b_addr then
                    fwd_2 <= '1';
                    alt_data_2 <= w_in.write_data;
                end if;
                if w_addr = c_addr then
                    fwd_3 <= '1';
                    alt_data_3 <= w_in.write_data;
                end if;
            end if;

            if stall = '0' then
                addr_1_reg <= d1_in.reg_1_addr;
                addr_2_reg <= d1_in.reg_2_addr;
                addr_3_reg <= d1_in.reg_3_addr;
            end if;

            -- Handle indirect register reads and debug reads using the B port
            b_addr := d1_in.reg_2_addr;
            if stall = '1' or d1_in.read_2_enable = '0' then
                if e_in.read_req = '1' and indirect_ack = '0' then
                    b_addr := e_in.reg_addr;
                    indirect_ack <= '1';
                elsif dbg_gpr_req = '1' then
                    b_addr := dbg_gpr_addr;
                    dbg_gpr_done <= '1';
                end if;
            end if;
            if dbg_gpr_req = '0' then
                dbg_gpr_done <= '0';
            end if;

	    if is_X(d1_in.reg_1_addr) then
		data_1 <= (others => 'X');
	    else
		data_1 <= registers(regfileaddr(d1_in.reg_1_addr));
	    end if;
	    if is_X(b_addr) then
		data_2 <= (others => 'X');
	    else
		data_2 <= registers(regfileaddr(b_addr));
	    end if;
	    if is_X(d1_in.reg_3_addr) then
		data_3 <= (others => 'X');
	    else
		data_3 <= registers(regfileaddr(d1_in.reg_3_addr));
	    end if;

        end if;
    end process register_write_0;

    -- asynchronous forwarding of write data
    register_read_0: process(all)
        variable out_data_1 : std_ulogic_vector(63 downto 0);
        variable out_data_2 : std_ulogic_vector(63 downto 0);
        variable out_data_3 : std_ulogic_vector(63 downto 0);
    begin
        out_data_1 := data_1;
        out_data_2 := data_2;
        out_data_3 := data_3;
        if fwd_1 = '1' then
            out_data_1 := alt_data_1;
        end if;
        if fwd_2 = '1' then
            out_data_2 := alt_data_2;
        end if;
        if fwd_3 = '1' then
            out_data_3 := alt_data_3;
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

        e_out.read_data <= data_2;
        e_out.ack <= indirect_ack;
    end process register_read_0;

    -- Latch read data and ack if dbg read requested and B port not busy
    dbg_register_read: process(clk)
    begin
        if rising_edge(clk) then
            if dbg_gpr_req = '1' then
                if dbg_ack = '0' and dbg_gpr_done = '1' then
                    dbg_data <= data_2;
                    dbg_ack <= '1';
                end if;
            else
                dbg_ack <= '0';
            end if;
        end if;
    end process;

    dbg_gpr_ack <= dbg_ack;
    dbg_gpr_data <= dbg_data;

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
        signal log_data : std_ulogic_vector(72 downto 0);
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
