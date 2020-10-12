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
        sub_select      : in  std_ulogic_vector(2 downto 0);
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
        vbpermq  : std_ulogic_vector(7 downto 0);
        vbp_sel  : std_ulogic_vector(31 downto 0);
        carry    : std_ulogic;
        oshift   : unsigned(3 downto 0);
        vs_ext   : std_ulogic_vector(7 downto 0);
        isum     : std_ulogic_vector(33 downto 0);
    end record;
    constant vec_state_init : vec_state := (ni => '0', sat => '0', all0 => '0', all1 => '0',
                                            vbpermq => (others => '0'), vbp_sel => (others => '0'),
                                            oshift => "0000", carry => '0', vs_ext => x"00",
                                            isum => (others => '0'),
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
        variable a_sh         : std_ulogic_vector(63 downto 0);
        variable b_sh         : std_ulogic_vector(63 downto 0);
        variable store_ab     : std_ulogic;
        variable vperm_result : std_ulogic_vector(63 downto 0);
        variable lvs_result   : std_ulogic_vector(63 downto 0);
        variable varith_res   : std_ulogic_vector(63 downto 0);
        variable cmp_result   : std_ulogic_vector(63 downto 0);
        variable log_result   : std_ulogic_vector(63 downto 0);
        variable move_result  : std_ulogic_vector(63 downto 0);
        variable gather_res   : std_ulogic_vector(63 downto 0);
        variable shift_result : std_ulogic_vector(63 downto 0);
        variable sum_result   : std_ulogic_vector(63 downto 0);
        variable all0, all1   : std_ulogic;
        variable cmpeq        : byte_comparison_t;
        variable cmpgt        : byte_comparison_t;
        variable cmpgtu       : byte_comparison_t;
        variable cmpaz        : byte_comparison_t;
        variable cmpbz        : byte_comparison_t;
        variable bv           : boolean;
        variable vbperm_byte  : std_ulogic_vector(7 downto 0);
        variable byte         : std_ulogic_vector(7 downto 0);
        variable vop_a        : std_ulogic_vector(71 downto 0);
        variable vop_b        : std_ulogic_vector(71 downto 0);
        variable vsum         : std_ulogic_vector(71 downto 0);
        variable cin          : std_ulogic;
        variable lenm1        : std_ulogic_vector(2 downto 0);
        variable oshift       : unsigned(3 downto 0);
        variable index        : std_ulogic_vector(4 downto 0);
        variable shift        : std_ulogic_vector(5 downto 0);
        variable shift_col    : std_ulogic_vector(2 downto 0);
        variable bsh          : std_ulogic_vector(2 downto 0);
        variable src_byte     : std_ulogic_vector(2 downto 0);
        variable byte_in_elt  : std_ulogic_vector(2 downto 0);
        variable elt_sign     : std_ulogic;
        variable shift_in     : std_ulogic_vector(15 downto 0);
        variable is_rotate    : std_ulogic;
        variable is_right_sh  : std_ulogic;
        variable shift_whole  : std_ulogic;
        variable is_empty     : std_ulogic;
        variable byte0, byte1 : std_ulogic_vector(8 downto 0);
        variable byte2, byte3 : std_ulogic_vector(8 downto 0);
        variable bsum0, bsum1 : std_ulogic_vector(8 downto 0);
        variable byte_sum     : std_ulogic_vector(9 downto 0);
        variable half0, half1 : std_ulogic_vector(16 downto 0);
        variable half_sum     : std_ulogic_vector(16 downto 0);
        variable word0, word1 : std_ulogic_vector(33 downto 0);
        variable word2        : std_ulogic_vector(33 downto 0);
        variable word_sum     : std_ulogic_vector(33 downto 0);
        variable total        : std_ulogic_vector(34 downto 0);
        variable signbit      : std_ulogic;
        variable sum1         : std_ulogic_vector(32 downto 0);
        variable sum2         : std_ulogic_vector(32 downto 0);
        variable saturate     : std_ulogic_vector(7 downto 0);
        variable sat_msb      : std_ulogic_vector(7 downto 0);
        variable sat_lsb      : std_ulogic_vector(7 downto 0);
        variable overflow     : std_ulogic;
        variable ovf_hi       : std_ulogic;
        variable ovf_lo       : std_ulogic;
    begin
        v := vst;

        a_sh := a_in;
        b_sh := b_in;
        store_ab := not e_in.second;

        -- do comparisons for vcmp*, vmin* and vmax*
        for i in 0 to 7 loop
            k := i * 8;
            cmpeq(i) := unsigned(a_in(k + 7 downto k)) = unsigned(b_in(k + 7 downto k));
            cmpgt(i) := signed(a_in(k + 7 downto k)) > signed(b_in(k + 7 downto k));
            cmpgtu(i) := unsigned(a_in(k + 7 downto k)) > unsigned(b_in(k + 7 downto k));
            cmpaz(i) := a_in(k + 7 downto k) = x"00";
            cmpbz(i) := b_in(k + 7 downto k) = x"00";
        end loop;

        lenm1 := std_ulogic_vector(unsigned(e_in.data_len(2 downto 0)) - 1);

        -- Compute permutation vector v.perm_sel
        if e_in.valid = '1' then
            case e_in.insn_type is
            when OP_XPERM =>
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
            when OP_VPERM =>
                -- OP_VPERM, columns 2b, 2c, 3b
                if e_in.insn(2) = '1' then
                    -- vsldoi
                    m := 16 - to_integer(unsigned(e_in.insn(9 downto 6)));
                    if e_in.second = '0' then
                        m := m + 8;
                    end if;
                    for i in 0 to 7 loop
                        k := i * 8;
                        v.perm_sel(k + 7 downto k) := "000" & std_ulogic_vector(to_unsigned(m, 5) + to_unsigned(i, 5));
                    end loop;
                elsif e_in.insn(4) = '0' then
                    -- vperm
                    v.perm_sel := not c_in;
                else
                    -- vpermr
                    v.perm_sel := c_in;
                end if;
            when OP_VMINMAX =>
                -- OP_VMINMAX, column 02
                -- e_in.insn(9) is 1 for vmin, 0 for vmax
                case e_in.insn(8 downto 6) is
                    when "100" =>
                        -- vmaxsb, vminsb
                        for i in 0 to 7 loop
                            k := i * 8;
                            b := '0';
                            if cmpgt(i) then
                                b := '1';
                            end if;
                            v.perm_sel(k + 7 downto k) := "000" & (b xor e_in.insn(9)) &
                                                          not e_in.second & std_ulogic_vector(to_unsigned(i, 3));
                        end loop;
                    when "000" =>
                        -- vmaxub, vminub
                        for i in 0 to 7 loop
                            k := i * 8;
                            b := '0';
                            if cmpgtu(i) then
                                b := '1';
                            end if;
                            v.perm_sel(k + 7 downto k) := "000" & (b xor e_in.insn(9)) &
                                                          not e_in.second & std_ulogic_vector(to_unsigned(i, 3));
                        end loop;
                    when "101" =>
                        -- vmaxsh, vminsh
                        for i in 0 to 3 loop
                            k := i * 16;
                            m := i * 2;
                            b := '0';
                            if cmpgt(m + 1) or (cmpeq(m + 1) and cmpgtu(m)) then
                                b := '1';
                            end if;
                            v.perm_sel(k + 7 downto k) := "000" & (b xor e_in.insn(9)) &
                                                          not e_in.second & std_ulogic_vector(to_unsigned(i, 2)) & '0';
                            v.perm_sel(k + 15 downto k + 8) := "000" & (b xor e_in.insn(9)) &
                                                               not e_in.second & std_ulogic_vector(to_unsigned(i, 2)) & '1';
                        end loop;
                    when "001" =>
                        -- vmaxuh, vminuh
                        for i in 0 to 3 loop
                            k := i * 16;
                            m := i * 2;
                            b := '0';
                            if cmpgtu(m + 1) or (cmpeq(m + 1) and cmpgtu(m)) then
                                b := '1';
                            end if;
                            v.perm_sel(k + 7 downto k) := "000" & (b xor e_in.insn(9)) &
                                                          not e_in.second & std_ulogic_vector(to_unsigned(i, 2)) & '0';
                            v.perm_sel(k + 15 downto k + 8) := "000" & (b xor e_in.insn(9)) &
                                                               not e_in.second & std_ulogic_vector(to_unsigned(i, 2)) & '1';
                        end loop;
                    when "110" =>
                        -- vmaxsw, vminsw
                        for i in 0 to 1 loop
                            bv := cmpgt(i * 4 + 3);
                            if cmpeq(i * 4 + 3) then
                                for m in i * 4 + 2 downto i * 4 loop
                                    bv := cmpgtu(m);
                                    if not cmpeq(m) then
                                        exit;
                                    end if;
                                end loop;
                            end if;
                            b := '0';
                            if bv then
                                b := '1';
                            end if;
                            for m in i * 4 to i * 4 + 3 loop
                                k := m * 8;
                                v.perm_sel(k + 7 downto k) := "000" & (b xor e_in.insn(9)) &
                                                              not e_in.second &
                                                              std_ulogic_vector(to_unsigned(m, 3));
                            end loop;
                        end loop;
                    when "010" =>
                        -- vmaxuw, vminuw
                        for i in 0 to 1 loop
                            for m in i * 4 + 3 downto i * 4 loop
                                bv := cmpgtu(m);
                                if not cmpeq(m) then
                                    exit;
                                end if;
                            end loop;
                            b := '0';
                            if bv then
                                b := '1';
                            end if;
                            for m in i * 4 to i * 4 + 3 loop
                                k := m * 8;
                                v.perm_sel(k + 7 downto k) := "000" & (b xor e_in.insn(9)) &
                                                              not e_in.second &
                                                              std_ulogic_vector(to_unsigned(m, 3));
                            end loop;
                        end loop;
                    when "111" =>
                        -- vmaxsd, vminsd
                        bv := cmpgt(7);
                        if cmpeq(7) then
                            for m in 6 downto 0 loop
                                bv := cmpgtu(m);
                                if not cmpeq(m) then
                                    exit;
                                end if;
                            end loop;
                        end if;
                        b := '0';
                        if bv then
                            b := '1';
                        end if;
                        for m in 0 to 7 loop
                            k := m * 8;
                            v.perm_sel(k + 7 downto k) := "000" & (b xor e_in.insn(9)) &
                                                          not e_in.second &
                                                          std_ulogic_vector(to_unsigned(m, 3));
                        end loop;
                    when others =>
                        -- vmaxud, vminud
                        for m in 7 downto 0 loop
                            bv := cmpgtu(m);
                            if not cmpeq(m) then
                                exit;
                            end if;
                        end loop;
                        b := '0';
                        if bv then
                            b := '1';
                        end if;
                        for m in 0 to 7 loop
                            k := m * 8;
                            v.perm_sel(k + 7 downto k) := "000" & (b xor e_in.insn(9)) &
                                                          not e_in.second &
                                                          std_ulogic_vector(to_unsigned(m, 3));
                        end loop;
                end case;
            when OP_VPACK =>
                -- OP_VPACK, column 0e
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
            when OP_VMERGE =>
                -- OP_VMERGE, column 0c
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
                        b_sh := std_ulogic_vector(resize(signed(e_in.insn(20 downto 16)), 64));
                        v.perm_sel := x"0808080808080808";
                    when "01101" =>
                        -- vspltish
                        b_sh := std_ulogic_vector(resize(signed(e_in.insn(20 downto 16)), 64));
                        v.perm_sel := x"0908090809080908";
                    when "01110" =>
                        -- vspltisw
                        b_sh := std_ulogic_vector(resize(signed(e_in.insn(20 downto 16)), 64));
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
            when OP_VBPERM =>
                -- vbpermq
                -- note we do LS then MS (R|1 then R) for vbpermq
                -- because the result is in the MS half of VRT
                for i in 0 to 7 loop
                    k := i * 8;
                    m := i * 4;
                    v.perm_sel(k + 7 downto k) := "0001" & b_in(k + 6) & not b_in(k + 5 downto k + 3);
                    v.vbp_sel(m + 3 downto m) := b_in(k + 7) & b_in(k + 2 downto k);
                end loop;
            when OP_VSHOCT =>
                b_sh := (others => '0');
                if e_in.insn(6) = '0' then
                    -- vslo
                    -- we do LS then MS because the shift count is in the
                    -- LS half of VRB
                    if e_in.second = '0' then
                        oshift := unsigned(b_in(6 downto 3));
                        v.oshift := oshift;
                    else
                        oshift := vst.oshift;
                    end if;
                    for i in 0 to 7 loop
                        k := i * 8;
                        index := '1' & e_in.second & std_ulogic_vector(to_unsigned(i, 3));
                        index := std_ulogic_vector(unsigned(index) - resize(oshift, 5));
                        if index(4) = '0' then
                            -- need a zero byte; only vst.b0 is known to be
                            -- zero, not b_in, so select byte f
                            v.perm_sel(k + 7 downto k) := x"0f";
                        else
                            -- bit 3 is inverted because the logic below
                            -- does vst.a0 & a_in, but we have LS then MS
                            v.perm_sel(k + 7 downto k) := "0001" & not index(3) & index(2 downto 0);
                        end if;
                    end loop;
                else
                    -- vsro, also LS then MS
                    if e_in.second = '0' then
                        oshift := unsigned(b_in(6 downto 3));
                        v.oshift := oshift;
                    else
                        oshift := vst.oshift;
                    end if;
                    for i in 0 to 7 loop
                        k := i * 8;
                        index := '0' & e_in.second & std_ulogic_vector(to_unsigned(i, 3));
                        index := std_ulogic_vector(unsigned(index) + resize(oshift, 5));
                        if index(4) = '1' then
                            -- need a zero byte, use index 0f
                            v.perm_sel(k + 7 downto k) := x"0f";
                        else
                            v.perm_sel(k + 7 downto k) := "0001" & not index(3) & index(2 downto 0);
                        end if;
                    end loop;
                end if;
            when OP_VSHIFT =>
                -- OP_VSHIFT, column 4
                store_ab := '1';
                is_rotate := '0';
                if e_in.insn(9 downto 8) = "00" then
                    is_rotate := '1';
                end if;
                is_right_sh := e_in.insn(9);
                shift_whole := '0';
                if e_in.insn(10 downto 6) = "00111" or e_in.insn(10 downto 6) = "01011" or
                    e_in.insn(10 downto 7) = "1110" then
                    -- vsl, vsr, vslv and vsrv
                    -- Note that vsl and vsr are done as per-byte shifts (like
                    -- vslv/vsrv) because P9's behaviour is to shift each byte
                    -- of VRA by the shift count in the corresponding byte of
                    -- VRB.  The arch requires all bytes of VRB to have the
                    -- same value in the bottom 3 bits.
                    shift_whole := '1';
                    -- vslv breaks the encoding pattern of left vs right shifts
                    if e_in.insn(10) = '1' then
                        is_right_sh := not e_in.insn(6);
                    end if;
                    if is_right_sh = '1' then
                        v.vs_ext := a_in(7 downto 0);
                    else
                        v.vs_ext := a_in(63 downto 56);
                    end if;
                end if;
                for i in 0 to 7 loop
                    k := i * 8;
                    shift_col := std_ulogic_vector(to_unsigned(i, 3)) and not lenm1;
                    -- Calculate permutation vector for rotating the bytes of
                    -- this element
                    if shift_whole = '1' then
                        shift := "000" & b_in(k + 2 downto k);
                    else
                        m := to_integer(unsigned(shift_col)) * 8;
                        shift := (b_in(m + 5 downto m + 3) and lenm1) & b_in(m + 2 downto m);
                    end if;
                    -- Compute where this byte of the output comes from
                    if is_right_sh = '1' then
                        -- right shifts
                        src_byte := std_ulogic_vector(to_unsigned(i, 3) + unsigned(shift(5 downto 3))) and lenm1;
                    else
                        -- left shifts
                        src_byte := std_ulogic_vector(to_unsigned(i, 3) - unsigned(shift(5 downto 3))) and lenm1;
                    end if;
                    v.perm_sel(k + 7 downto k) := "00011" & (src_byte or shift_col);
                    -- Does this byte of the input get shifted out of existence?
                    is_empty := '0';
                    byte_in_elt := std_ulogic_vector(to_unsigned(i, 3)) and lenm1;
                    if is_right_sh = '1' then
                        if unsigned(byte_in_elt) < unsigned(shift(5 downto 3)) then
                            is_empty := '1';
                        end if;
                    elsif is_rotate = '0' then
                        if unsigned(byte_in_elt) > unsigned(shift(5 downto 3) xor lenm1) then
                            is_empty := '1';
                        end if;
                    end if;
                    -- For vsra*, work out the sign of this element
                    elt_sign := '0';
                    if e_in.is_signed = '1' then
                        m := to_integer(unsigned(shift_col or lenm1)) * 8;
                        elt_sign := a_in(m + 7);
                    end if;
                    -- Shift this byte left or right, or replace it with 0 or -1
                    bsh := shift(2 downto 0);
                    if is_right_sh = '1' and bsh /= "000" then
                        bsh := std_ulogic_vector(- signed(bsh));
                        if (std_ulogic_vector(to_unsigned(i + 1, 3)) and lenm1) = "000" then
                            -- leftmost byte of element
                            if shift_whole = '1' and e_in.second = '1' then
                                shift_in(15 downto 8) := vst.vs_ext;
                            else
                                shift_in(15 downto 8) := (others => elt_sign);
                            end if;
                        else
                            shift_in(15 downto 8) := a_in(k + 15 downto k + 8);
                        end if;
                        shift_in(7 downto 0) := a_in(k + 7 downto k);
                    else
                        if (std_ulogic_vector(to_unsigned(i, 3)) and lenm1) = "000" then
                            -- rightmost byte of element
                            if shift_whole = '1' and e_in.second = '1' then
                                shift_in(7 downto 0) := vst.vs_ext;
                            elsif is_rotate = '1' then
                                m := to_integer(unsigned(std_ulogic_vector(to_unsigned(i, 3)) or lenm1)) * 8;
                                shift_in(7 downto 0) := a_in(m + 7 downto m);
                            else
                                shift_in(7 downto 0) := (others => '0');
                            end if;
                        else
                            shift_in(7 downto 0) := a_in(k - 1 downto k - 8);
                        end if;
                        shift_in(15 downto 8) := a_in(k + 7 downto k);
                    end if;
                    if is_empty = '0' then
                        n := to_integer(unsigned(bsh));
                        a_sh(k + 7 downto k) := shift_in(15 - n downto 8 - n);
                    else
                        a_sh(k + 7 downto k) := (others => elt_sign);
                    end if;
                end loop;
            when others =>
                v.perm_sel := (others => '0');
            end case;
        end if;

        if e_in.valid = '1' and store_ab = '1' then
            v.a0 := a_sh;
            v.b0 := b_sh;
        end if;

        data := vst.a0 & a_in & vst.b0 & b_in;
        for i in 0 to 7 loop
            k := i * 8;
            m := to_integer(unsigned(vst.perm_sel(k + 4 downto k)));
            n := m * 8;
            vperm_result(k + 7 downto k) := data(n + 7 downto n);
        end loop;

        cmp_result := (others => '0');
        if e_in.second = '0' then
            all0 := '1';
            all1 := '1';
        else
            all0 := vst.all0;
            all1 := vst.all1;
        end if;
        case e_in.insn(9 downto 6) & e_in.insn(0) is
            when "00000" =>
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
            when "00001" =>
                -- vcmpneb
                for i in 0 to 7 loop
                    k := i * 8;
                    if not cmpeq(i) then
                        cmp_result(k + 7 downto k) := x"ff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "01001" =>
                -- vcmpnezb
                for i in 0 to 7 loop
                    k := i * 8;
                    if not cmpeq(i) or cmpaz(i) or cmpbz(i) then
                        cmp_result(k + 7 downto k) := x"ff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "00010" =>
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
            when "00011" =>
                -- vcmpneh
                for i in 0 to 3 loop
                    k := i * 16;
                    m := i * 2;
                    if not (cmpeq(m) and cmpeq(m + 1)) then
                        cmp_result(k + 15 downto k) := x"ffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "01011" =>
                -- vcmpnezh
                for i in 0 to 3 loop
                    k := i * 16;
                    m := i * 2;
                    if not (cmpeq(m) and cmpeq(m + 1)) or
                        (cmpaz(m) and cmpaz(m + 1)) or (cmpbz(m) and cmpbz(m + 1)) then
                        cmp_result(k + 15 downto k) := x"ffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "00100" =>
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
            when "00101" =>
                -- vcmpnew
                for i in 0 to 1 loop
                    k := i * 32;
                    m := i * 4;
                    if not (cmpeq(m) and cmpeq(m + 1) and cmpeq(m + 2) and cmpeq(m + 3)) then
                        cmp_result(k + 31 downto k) := x"ffffffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "01101" =>
                -- vcmpnezw
                for i in 0 to 1 loop
                    k := i * 32;
                    m := i * 4;
                    if not (cmpeq(m) and cmpeq(m + 1) and cmpeq(m + 2) and cmpeq(m + 3)) or
                        (cmpaz(m) and cmpaz(m + 1) and cmpaz(m + 2) and cmpaz(m + 3)) or
                        (cmpbz(m) and cmpbz(m + 1) and cmpbz(m + 2) and cmpbz(m + 3)) then
                        cmp_result(k + 31 downto k) := x"ffffffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "00111" =>
                -- vcmpequd
                if cmpeq(0) and cmpeq(1) and cmpeq(2) and cmpeq(3) and
                    cmpeq(4) and cmpeq(5) and cmpeq(6) and cmpeq(7) then
                    cmp_result := (others => '1');
                    all0 := '0';
                else
                    all1 := '0';
                end if;
            when "10000" =>
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
            when "10010" =>
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
            when "10100" =>
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
            when "10111" =>
                -- vcmpgtud
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
            when "11000" =>
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
            when "11010" =>
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
            when "11100" =>
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
            when "11111" =>
                -- vcmpgtsd
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

        -- compute vector logical result
        if e_in.insn(5) = '1' then
            -- vsel
            log_result := (a_in and not c_in) or (b_in and c_in);
        else
            case e_in.insn(8 downto 6) is
                when "000" =>
                    log_result := a_in and b_in;
                when "001" =>
                    log_result := a_in and not b_in;
                when "010" =>
                    log_result := a_in or b_in;
                when "011" =>
                    log_result := a_in xor b_in;
                when "100" =>
                    log_result := not (a_in or b_in);
                when "101" =>
                    log_result := a_in or not b_in;
                when "110" =>
                    log_result := not (a_in and b_in);
                when others =>
                    log_result := a_in xnor b_in;
            end case;
        end if;

        -- compute mfvscr/mfvsr*/mtvsr* result
        if e_in.insn(26) = '0' then
            -- mfvscr
            move_result := (others => '0');
            if e_in.second = '1' then
                move_result(16) := vst.ni;
                move_result(0) := vst.sat;
            end if;
        elsif e_in.insn(8) = '0' then
            -- mfvsr*
            move_result := c_in;
        else
            -- mtvsr*
            if e_in.second = '0' then
                move_result := a_in;
            elsif e_in.insn(9) = '1' then
                -- mtvsrdd or mtvsrws
                if e_in.insn(6) = '1' then
                    move_result := b_in;        -- mtvsrdd
                else
                    move_result := a_in;        -- mtvsrws
                end if;
            else
                move_result := (others => '0');
            end if;
        end if;
        if e_in.is_32bit = '1' then
            if e_in.insn(9) = '1' then
                -- mtvsrws
                move_result(63 downto 32) := move_result(31 downto 0);
            else
                b := e_in.sign_extend and move_result(31);
                move_result(63 downto 32) := (others => b);
            end if;
        end if;

        if e_in.insn(6) = '0' then
            -- vgbbd result
            for i in 0 to 7 loop
                for j in 0 to 7 loop
                    gather_res(i * 8 + j) := b_in(j * 8 + i);
                end loop;
            end loop;
        else
            -- vbpermq result
            for i in 0 to 7 loop
                k := i * 8;
                m := i * 4;
                byte := vperm_result(k + 7 downto k);
                vbperm_byte(i) := byte(to_integer(unsigned(not vst.vbp_sel(m + 2 downto m)))) and
                                  not vst.vbp_sel(m + 3);
            end loop;
            gather_res := (others => '0');
            if vec_in_progress = '0' then
                gather_res(7 downto 0) := vst.vbpermq;
                gather_res(15 downto 8) := vbperm_byte;
            end if;
            if e_in.valid = '1' then
                v.vbpermq := vbperm_byte;
            end if;
        end if;

        -- execute mtvscr
        if vec_valid = '1' and e_in.insn_type = OP_MTVSCR and e_in.second = '1' then
            v.ni := b_in(16);
            v.sat := b_in(0);
        end if;

        -- vector arithmetic
        cin := e_in.insn(10);           -- 1 for vsub, 0 for vadd
        if e_in.second = '1' and e_in.insn(9 downto 6) = "0100" then
            -- vadduqm, vsubuqm; note these are done LS then MS
            cin := vst.carry;
        end if;
        for i in 0 to 7 loop
            k := i * 8;
            m := i * 9;
            vop_a(m + 7 downto m) := a_in(k + 7 downto k);
            if e_in.insn(10) = '0' then
                vop_b(m + 7 downto m) := b_in(k + 7 downto k);
            else
                vop_b(m + 7 downto m) := not b_in(k + 7 downto k);
            end if;
            -- this tests (i + 1) mod data_len = 0
            if (lenm1 and not std_ulogic_vector(to_unsigned(i, 3))) = "000" then
                -- segment the adder here
                vop_a(m + 8) := cin;
                vop_b(m + 8) := cin;
            else
                -- propagate the carry
                vop_a(m + 8) := '1';
                vop_b(m + 8) := '0';
            end if;
        end loop;
        vsum := std_ulogic_vector(unsigned(vop_a) + unsigned(vop_b) + cin);
        -- Do overflow detection for saturation
        -- We abuse the e_in.sign_extend flag as a indication of which
        -- instructions do saturation.
        saturate := x"00";
        sat_msb := x"00";
        sat_lsb := x"00";
        if e_in.sign_extend = '1' then
            overflow := '0';
            signbit := '0';
            for i in 7 downto 0 loop
                k := i * 8;
                m := i * 9;
                -- if (i + 1) mod data_len = 0
                if (lenm1 and not std_ulogic_vector(to_unsigned(i, 3))) = "000" then
                    if e_in.is_signed = '0' then
                        -- unsigned overflow: carry=1 for add, carry=0 for sub
                        overflow := cin xor vsum(m + 8);
                        signbit := cin;
                        sat_msb(i) := not cin;
                    else
                        -- signed overflow: if result sign /= both operand signs
                        ovf_hi := not vop_a(m + 7) and not vop_b(m + 7) and vsum(m + 7);
                        ovf_lo := vop_a(m + 7) and vop_b(m + 7) and not vsum(m + 7);
                        overflow := ovf_hi or ovf_lo;
                        signbit := ovf_lo;
                        sat_msb(i) := signbit;
                    end if;
                else
                    sat_msb(i) := not signbit;
                end if;
                saturate(i) := overflow;
                sat_lsb(i) := not signbit;
                if overflow = '1' and e_in.insn_type = OP_VARITH and vec_valid = '1' then
                    v.sat := '1';
                end if;
            end loop;
        end if;
        -- generate the output
        for i in 0 to 7 loop
            k := i * 8;
            m := i * 9;
            if saturate(i) = '1' then
                varith_res(k + 7) := sat_msb(i);
                varith_res(k + 6 downto k) := (others => sat_lsb(i));
            else
                varith_res(k + 7 downto k) := vsum(m + 7 downto m);
            end if;
        end loop;
        v.carry := vsum(71);

        -- Sum-across logic
        word0 := a_in(31) & a_in(31) & a_in(31 downto 0);
        word1 := a_in(63) & a_in(63) & a_in(63 downto 32);
        word_sum := std_ulogic_vector(unsigned(word0) + unsigned(word1));
        if vec_valid = '1' then
            if e_in.second = '0' and e_in.insn_type = OP_VSUM and e_in.insn(8 downto 6) = "110" then
                v.isum := word_sum;
            else
                v.isum := (others => '0');
            end if;
        end if;

        word2 := std_ulogic_vector(unsigned(b_in(31) & b_in(31) & b_in(31 downto 0)) +
                                   unsigned(vst.isum));

        if e_in.data_len(2) = '1' then
            -- vsumsws, vsum2sws
            sum_result(63 downto 32) := x"00000000";
            if e_in.second = '1' or e_in.insn(8) = '0' then
                total := std_ulogic_vector(unsigned(word2(33) & word2) +
                                           unsigned(word_sum(33) & word_sum));
                -- work out whether to saturate
                if total(34 downto 31) = "0000" or total(34 downto 31) = "1111" then
                    sum_result(31 downto 0) := total(31 downto 0);
                else
                    if e_in.insn_type = OP_VSUM and vec_valid = '1' then
                        v.sat := '1';
                    end if;
                    if total(34) = '0' then
                        sum_result(31 downto 0) := x"7fffffff";
                    else
                        sum_result(31 downto 0) := x"80000000";
                    end if;
                end if;
            else
                sum_result(31 downto 0) := x"00000000";
            end if;

        else
            -- vsum4sbs, vsum4ubs, vsum4shs
            for i in 0 to 1 loop
                -- sum across groups of 4 bytes (signed or unsigned)
                k := i * 32;
                byte0 := (e_in.is_signed and a_in(k + 7)) & a_in(k + 7 downto k);
                byte1 := (e_in.is_signed and a_in(k + 15)) & a_in(k + 15 downto k + 8);
                bsum0 := std_ulogic_vector(unsigned(byte0) + unsigned(byte1));
                byte2 := (e_in.is_signed and a_in(k + 23)) & a_in(k + 23 downto k + 16);
                byte3 := (e_in.is_signed and a_in(k + 31)) & a_in(k + 31 downto k + 24);
                bsum1 := std_ulogic_vector(unsigned(byte2) + unsigned(byte3));
                byte_sum := std_ulogic_vector(unsigned((e_in.is_signed and bsum0(8)) & bsum0) +
                                              unsigned((e_in.is_signed and bsum1(8)) & bsum1));

                -- sum across half-words, always signed
                half0 := a_in(k + 15) & a_in(k + 15 downto k);
                half1 := a_in(k + 31) & a_in(k + 31 downto k + 16);
                half_sum := std_ulogic_vector(unsigned(half0) + unsigned(half1));

                if e_in.data_len(0) = '1' then
                    signbit := e_in.is_signed and byte_sum(9);
                    sum1(32 downto 10) := (others => signbit);
                    sum1(9 downto 0) := byte_sum;
                else
                    sum1 := std_ulogic_vector(resize(signed(half_sum), 33));
                end if;

                signbit := e_in.is_signed and b_in(k + 31);
                sum2 := std_ulogic_vector(unsigned(signbit & b_in(k + 31 downto k)) +
                                          unsigned(sum1));
                
                if (e_in.is_signed and sum2(31)) = sum2(32) then
                    sum_result(k + 31 downto k) := sum2(31 downto 0);
                else
                    if e_in.insn_type = OP_VSUM and vec_valid = '1' then
                        v.sat := '1';
                    end if;
                    if e_in.is_signed = '0' then
                        sum_result(k + 31 downto k) := x"ffffffff";
                    elsif sum2(32) = '0' then
                        sum_result(k + 31 downto k) := x"7fffffff";
                    else
                        sum_result(k + 31 downto k) := x"80000000";
                    end if;
                end if;
            end loop;
        end if;

        case sub_select is
            when "000" =>
                vec_result <= varith_res;
            when "001" =>
                vec_result <= lvs_result;
            when "010" =>
                vec_result <= cmp_result;
            when "011" =>
                vec_result <= log_result;
            when "100" =>
                vec_result <= move_result;
            when "101" =>
                vec_result <= gather_res;
            when "110" =>
                vec_result <= sum_result;
            when others =>
                vec_result <= vperm_result;
        end case;

        -- update state
        vst_in <= v;
    end process;
end architecture behaviour;
