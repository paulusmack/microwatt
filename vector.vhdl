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
        vec_cr6         : out std_ulogic_vector(3 downto 0);
        vec_result      : out std_ulogic_vector(63 downto 0)
        );
end entity vector_unit;

architecture behaviour of vector_unit is
    
    -- State for vector instructions
    type vec_state is record
        ni       : std_ulogic;          -- non-IEEE mode
        sat      : std_ulogic;          -- saturation flag
        a0       : std_ulogic_vector(63 downto 0);
        b0       : std_ulogic_vector(63 downto 0);
        perm_sel : std_ulogic_vector(63 downto 0);
        all0     : std_ulogic;
        all1     : std_ulogic;
    end record;
    constant vec_state_init : vec_state := (ni => '0', sat => '0', all0 => '0', all1 => '0',
                                            others => (others => '0'));

    signal vst, vst_in : vec_state;

    type byte_comparison_t is array(0 to 7) of boolean;

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
        variable b            : std_ulogic;
        variable data         : std_ulogic_vector(255 downto 0);
        variable sum          : unsigned(7 downto 0);
        variable vperm_result : std_ulogic_vector(63 downto 0);
        variable lvs_result   : std_ulogic_vector(63 downto 0);
        variable vscr_result  : std_ulogic_vector(63 downto 0);
        variable cmp_result   : std_ulogic_vector(63 downto 0);
        variable all0, all1   : std_ulogic;
        variable cmpeq        : byte_comparison_t;
        variable cmpgt        : byte_comparison_t;
        variable cmpgtu       : byte_comparison_t;
        variable bv           : boolean;
    begin
        v := vst;
        if e_in.valid = '1' and e_in.second = '0' then
            v.a0 := a_in;
            v.b0 := b_in;
        end if;
        if e_in.valid = '1' then
            if e_in.insn(31) = '1' then
                -- OP_XPERM
                if e_in.second = '0' then
                    b := e_in.insn(9);
                else
                    b := e_in.insn(8);
                end if;
                for i in 0 to 7 loop
                    k := i * 8;
                    v.perm_sel(k + 7 downto k) := "000" & not e_in.second &
                                                  not b & std_ulogic_vector(to_unsigned(i, 3));
                end loop;
            elsif e_in.insn(5) = '1' then
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

        -- do comparisons for vcmp*
        for i in 0 to 7 loop
            k := i * 8;
            cmpeq(i) := unsigned(a_in(k + 7 downto k)) = unsigned(b_in(k + 7 downto k));
            cmpgt(i) := signed(a_in(k + 7 downto k)) > signed(b_in(k + 7 downto k));
            cmpgtu(i) := unsigned(a_in(k + 7 downto k)) > unsigned(b_in(k + 7 downto k));
        end loop;
        cmp_result := (others => '0');
        if e_in.second = '0' then
            all0 := '1';
            all1 := '1';
        else
            all0 := vst.all0;
            all1 := vst.all1;
        end if;
        case e_in.insn(9 downto 6) is
            when "0000" =>
                -- vcmpequb
                for i in 0 to 7 loop
                    k := i * 8;
                    if cmpeq(i) then
                        cmp_result(k + 7 downto k) := x"ff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "0001" =>
                -- vcmpequh
                for i in 0 to 3 loop
                    k := i * 16;
                    m := i * 2;
                    if cmpeq(m) and cmpeq(m + 1) then
                        cmp_result(k + 15 downto k) := x"ffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "0010" =>
                -- vcmpequw
                for i in 0 to 1 loop
                    k := i * 32;
                    m := i * 4;
                    if cmpeq(m) and cmpeq(m + 1) and cmpeq(m + 2) and cmpeq(m + 3) then
                        cmp_result(k + 31 downto k) := x"ffffffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "0011" =>
                -- vcmpequd (and vcmpeqfp, but that isn't decoded yet)
                if cmpeq(0) and cmpeq(1) and cmpeq(2) and cmpeq(3) and
                    cmpeq(4) and cmpeq(5) and cmpeq(6) and cmpeq(7) then
                    cmp_result := (others => '1');
                    all0 := '0';
                else
                    all1 := '0';
                end if;
            when "1000" =>
                -- vcmpgtub
                for i in 0 to 7 loop
                    k := i * 8;
                    if cmpgtu(i) then
                        cmp_result(k + 7 downto k) := x"ff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "1001" =>
                -- vcmpgtuh
                for i in 0 to 3 loop
                    k := i * 16;
                    m := i * 2;
                    if cmpgtu(m + 1) or (cmpeq(m + 1) and cmpgtu(m)) then
                        cmp_result(k + 15 downto k) := x"ffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "1010" =>
                -- vcmpgtuw
                for i in 0 to 1 loop
                    k := i * 32;
                    for m in i * 4 + 3 downto i * 4 loop
                        bv := cmpgtu(m);
                        if not cmpeq(m) then
                            exit;
                        end if;
                    end loop;
                    if bv then
                        cmp_result(k + 31 downto k) := x"ffffffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "1011" =>
                -- vcmpgtud (and vcmpgtfp, but that isn't decoded yet)
                for m in 7 downto 0 loop
                    bv := cmpgtu(m);
                    if not cmpeq(m) then
                        exit;
                    end if;
                end loop;
                if bv then
                    cmp_result := (others => '1');
                    all0 := '0';
                else
                    all1 := '0';
                end if;
            when "1100" =>
                -- vcmpgtsb
                for i in 0 to 7 loop
                    k := i * 8;
                    if cmpgt(i) then
                        cmp_result(k + 7 downto k) := x"ff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "1101" =>
                -- vcmpgtsh
                for i in 0 to 3 loop
                    k := i * 16;
                    m := i * 2;
                    if cmpgt(m + 1) or (cmpeq(m + 1) and cmpgtu(m)) then
                        cmp_result(k + 15 downto k) := x"ffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "1110" =>
                -- vcmpgtsw
                for i in 0 to 1 loop
                    k := i * 32;
                    bv := cmpgt(i * 4 + 3);
                    if cmpeq(i * 4 + 3) then
                        for m in i * 4 + 2 downto i * 4 loop
                            bv := cmpgtu(m);
                            if not cmpeq(m) then
                                exit;
                            end if;
                        end loop;
                    end if;
                    if bv then
                        cmp_result(k + 31 downto k) := x"ffffffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "1111" =>
                -- vcmpgtsd (and vcmpbfp, but that isn't decoded yet)
                bv := cmpgt(7);
                if cmpeq(7) then
                    for m in 6 downto 0 loop
                        bv := cmpgtu(m);
                        if not cmpeq(m) then
                            exit;
                        end if;
                    end loop;
                end if;
                if bv then
                    cmp_result := (others => '1');
                    all0 := '0';
                else
                    all1 := '0';
                end if;
            when others =>
        end case;
        vec_cr6 <= all1 & '0' & all0 & '0';
        if vec_valid = '1' then
            v.all0 := all0;
            v.all1 := all1;
        end if;

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

        -- compute result for mfvscr
        vscr_result := (others => '0');
        if e_in.second = '1' then
            vscr_result(16) := vst.ni;
            vscr_result(0) := vst.sat;
        end if;

        -- execute mtvscr
        if vec_valid = '1' and e_in.insn_type = OP_MTVSCR and e_in.second = '1' then
            v.ni := b_in(16);
            v.sat := b_in(0);
        end if;

        case e_in.insn_type is
            when OP_MFVSCR =>
                vec_result <= vscr_result;
            when OP_LVS =>
                vec_result <= lvs_result;
            when OP_VCMP =>
                vec_result <= cmp_result;
            when others =>
                vec_result <= vperm_result;
        end case;

        -- update state
        vst_in <= v;
    end process;
end architecture behaviour;
