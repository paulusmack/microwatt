library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.decode_types.all;
use work.common.all;
use work.helpers.all;
use work.crhelpers.all;
use work.insn_helpers.all;
use work.ppc_fx_insns.all;

entity vector_unit is
    port (
        clk             : in  std_ulogic;
        rst             : in  std_ulogic;
        vec_valid       : in  std_ulogic;
        vec_in_progress : in  std_ulogic;
        a_in            : in  std_ulogic_vector(63 downto 0);
        b_in            : in  std_ulogic_vector(63 downto 0);
        c_in            : in  std_ulogic_vector(63 downto 0);
        e_in            : in  Decode2ToExecute1Type;
        vec_result      : out std_ulogic_vector(63 downto 0)
        );
end entity vector_unit;

architecture behaviour of vector_unit is
    
    -- State for vector instructions
    type vec_state is record
        a0       : std_ulogic_vector(63 downto 0);
        b0       : std_ulogic_vector(63 downto 0);
        perm_sel : std_ulogic_vector(63 downto 0);
    end record;
    constant vec_state_init : vec_state := (others => (others => '0'));

    signal vst, vst_in : vec_state;

begin

    vector_0: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                vst <= vec_state_init;
            else
                vst <= vst_in;
            end if;
        end if;
    end process;

    vector_1: process(all)
        variable v            : vec_state;
        variable k, m, n      : integer;
        variable data         : std_ulogic_vector(255 downto 0);
        variable sum          : unsigned(7 downto 0);
        variable lvs_result   : std_ulogic_vector(63 downto 0);
        variable vperm_result : std_ulogic_vector(63 downto 0);
    begin
        v := vst;
        if e_in.valid = '1' and e_in.second = '0' then
            v.a0 := a_in;
            v.b0 := b_in;
        end if;
        if e_in.valid = '1' then
            if e_in.insn(5) = '1' then
                -- OP_VPERM
                if e_in.insn(4) = '0' then
                    -- vperm
                    v.perm_sel := not c_in;
                else
                    -- vpermr
                    v.perm_sel := c_in;
                end if;
            elsif e_in.insn(1) = '1' then
                -- OP_VPACK
                if e_in.insn(6) = '0' then
                    -- vpkuhum
                    for i in 0 to 7 loop
                        k := i * 8;
                        m := i * 2;
                        if e_in.second = '0' then
                            m := m + 16;
                        end if;
                        v.perm_sel(k + 7 downto k) := std_ulogic_vector(to_unsigned(m, 8));
                    end loop;
                elsif e_in.insn(10) = '0' then
                    -- vpkuwum
                    for i in 0 to 3 loop
                        k := i * 16;
                        m := i * 4;
                        if e_in.second = '0' then
                            m := m + 16;
                        end if;
                        v.perm_sel(k + 7 downto k) := std_ulogic_vector(to_unsigned(m, 8));
                        v.perm_sel(k + 15 downto k + 8) := std_ulogic_vector(to_unsigned(m + 1, 8));
                    end loop;
                else
                    -- vpkudum
                    for i in 0 to 1 loop
                        k := i * 32;
                        m := i * 8;
                        if e_in.second = '0' then
                            m := m + 16;
                        end if;
                        v.perm_sel(k + 7 downto k) := std_ulogic_vector(to_unsigned(m, 8));
                        v.perm_sel(k + 15 downto k + 8) := std_ulogic_vector(to_unsigned(m + 1, 8));
                        v.perm_sel(k + 23 downto k + 16) := std_ulogic_vector(to_unsigned(m + 2, 8));
                        v.perm_sel(k + 31 downto k + 24) := std_ulogic_vector(to_unsigned(m + 3, 8));
                    end loop;
                end if;
            else
                -- OP_VMERGE
                case e_in.insn(10 downto 6) is
                    when "01000" =>
                        -- vspltb
                        for i in 0 to 7 loop
                            k := i * 8;
                            v.perm_sel(k + 7 downto k) := "0000" & not e_in.insn(19 downto 16);
                        end loop;
                    when "01001" =>
                        -- vsplth
                        for i in 0 to 3 loop
                            k := i * 16;
                            v.perm_sel(k + 7 downto k) := "0000" & not e_in.insn(18 downto 16) & '0';
                            v.perm_sel(k + 15 downto k + 8) := "0000" & not e_in.insn(18 downto 16) & '1';
                        end loop;
                    when "01010" =>
                        -- vspltw
                        for i in 0 to 1 loop
                            k := i * 32;
                            v.perm_sel(k + 7 downto k) := "0000" & not e_in.insn(17 downto 16) & "00";
                            v.perm_sel(k + 15 downto k + 8) := "0000" & not e_in.insn(17 downto 16) & "01";
                            v.perm_sel(k + 23 downto k + 16) := "0000" & not e_in.insn(17 downto 16) & "10";
                            v.perm_sel(k + 31 downto k + 24) := "0000" & not e_in.insn(17 downto 16) & "11";
                        end loop;
                    when "01100" =>
                        -- vspltisb
                        v.b0 := std_ulogic_vector(resize(signed(e_in.insn(20 downto 16)), 64));
                        v.perm_sel := x"0808080808080808";
                    when "01101" =>
                        -- vspltish
                        v.b0 := std_ulogic_vector(resize(signed(e_in.insn(20 downto 16)), 64));
                        v.perm_sel := x"0908090809080908";
                    when "01110" =>
                        -- vspltisw
                        v.b0 := std_ulogic_vector(resize(signed(e_in.insn(20 downto 16)), 64));
                        v.perm_sel := x"0b0a09080b0a0908";
                    when "00000" =>
                        -- vmrghb
                        if e_in.second = '0' then
                            v.perm_sel := x"1f0f1e0e1d0d1c0c";
                        else
                            v.perm_sel := x"1b0b1a0a19091808";
                        end if;
                    when "00100" =>
                        -- vmrglb
                        if e_in.second = '0' then
                            v.perm_sel := x"1707160615051404";
                        else
                            v.perm_sel := x"1303120211011000";
                        end if;
                    when "00001" =>
                        -- vmrghh
                        if e_in.second = '0' then
                            v.perm_sel := x"1f1e0f0e1d1c0d0c";
                        else
                            v.perm_sel := x"1b1a0b0a19180908";
                        end if;
                    when "00101" =>
                        -- vmrglh
                        if e_in.second = '0' then
                            v.perm_sel := x"1716070615140504";
                        else
                            v.perm_sel := x"1312030211100100";
                        end if;
                    when "00010" =>
                        -- vmrghw
                        if e_in.second = '0' then
                            v.perm_sel := x"1f1e1d1c0f0e0d0c";
                        else
                            v.perm_sel := x"1b1a19180b0a0908";
                        end if;
                    when "00110" =>
                        -- vmrglw
                        if e_in.second = '0' then
                            v.perm_sel := x"1716151407060504";
                        else
                            v.perm_sel := x"1312111003020100";
                        end if;
                    when "11110" =>
                        -- vmrgew
                        if e_in.second = '0' then
                            v.perm_sel := x"1f1e1d1c0f0e0d0c";
                        else
                            v.perm_sel := x"1716151407060504";
                        end if;
                    when "11010" =>
                        -- vmrgow
                        if e_in.second = '0' then
                            v.perm_sel := x"1b1a19180b0a0908";
                        else
                            v.perm_sel := x"1312111003020100";
                        end if;
                    when others =>
                        v.perm_sel := (others => '0');
                end case;
            end if;
        end if;

        data := vst.a0 & a_in & vst.b0 & b_in;
        for i in 0 to 7 loop
            k := i * 8;
            m := to_integer(unsigned(vst.perm_sel(k + 4 downto k)));
            n := m * 8;
            vperm_result(k + 7 downto k) := data(n + 7 downto n);
        end loop;

        -- compute result for lvsl or lvsr
        sum := (others => '0');
        sum(3 downto 0) := unsigned(a_in(3 downto 0)) + unsigned(b_in(3 downto 0));
        if e_in.insn(6) = '1' then
            -- lvsr
            sum := to_unsigned(16, 8) - sum;
        end if;
        if e_in.second = '1' then
            sum := sum + to_unsigned(8, 8);
        end if;
        for i in 0 to 7 loop
            k := i * 8;
            lvs_result(k + 7 downto k) := std_ulogic_vector(sum + to_unsigned(7 - i, 8));
        end loop;

        case e_in.insn_type is
            when OP_LVS =>
                vec_result <= lvs_result;
            when others =>
                vec_result <= vperm_result;
        end case;

        -- update state
        vst_in <= v;
    end process;
end architecture behaviour;
