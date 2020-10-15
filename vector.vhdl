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
        vs_ext_l : std_ulogic_vector(7 downto 0);
        vs_ext_r : std_ulogic_vector(7 downto 0);
        isum     : std_ulogic_vector(33 downto 0);
    end record;
    constant vec_state_init : vec_state := (ni => '0', sat => '0', all0 => '0', all1 => '0',
                                            vbpermq => (others => '0'), vbp_sel => (others => '0'),
                                            oshift => "0000", carry => '0',
                                            vs_ext_l => x"00", vs_ext_r => x"00",
                                            isum => (others => '0'),
                                            others => (others => '0'));

    signal vst, vst_in : vec_state;

    type byte_comparison_t is array(0 to 7) of boolean;

    signal lenm1        : std_ulogic_vector(2 downto 0);
    signal log_len      : std_ulogic_vector(1 downto 0);
    signal vperm_result : std_ulogic_vector(63 downto 0);
    signal lvs_result   : std_ulogic_vector(63 downto 0);
    signal varith_res   : std_ulogic_vector(63 downto 0);
    signal cmp_result   : std_ulogic_vector(63 downto 0);
    signal log_result   : std_ulogic_vector(63 downto 0);
    signal move_result  : std_ulogic_vector(63 downto 0);
    signal gather_res   : std_ulogic_vector(63 downto 0);
    signal sum_result   : std_ulogic_vector(63 downto 0);
    signal vgbbd_result : std_ulogic_vector(63 downto 0);
    signal vbperm_byte  : std_ulogic_vector(7 downto 0);
    signal cin          : std_ulogic;
    signal is_subtract  : std_ulogic;
    signal addr_seg     : std_ulogic_vector(7 downto 0);
    signal vop_a        : std_ulogic_vector(71 downto 0);
    signal vop_b        : std_ulogic_vector(71 downto 0);
    signal vsum         : std_ulogic_vector(71 downto 0);
    signal byte_ovf     : std_ulogic_vector(7 downto 0);
    signal sovf_lo      : std_ulogic_vector(7 downto 0);
    signal sovf_hi      : std_ulogic_vector(7 downto 0);
    signal uovf_lo      : std_ulogic_vector(7 downto 0);
    signal uovf_hi      : std_ulogic_vector(7 downto 0);
    signal overflow     : std_ulogic_vector(7 downto 0);
    signal sat_msb      : std_ulogic_vector(7 downto 0);
    signal sat_lsb      : std_ulogic_vector(7 downto 0);
    signal satb0        : std_ulogic_vector(7 downto 0);
    signal satb7        : std_ulogic_vector(7 downto 0);
    signal perm_data    : std_ulogic_vector(255 downto 0);
    signal mtvsr_a      : std_ulogic_vector(63 downto 0);
    signal mfvsr_c      : std_ulogic_vector(63 downto 0);
    signal move_sel     : std_ulogic_vector(1 downto 0);
    signal vscr_enable  : std_ulogic;

    -- Spread out bits from the MSB of each element down to other bytes of the
    -- element, based on the element length encoded in sel.
    function spreadbits(sel: std_ulogic_vector(1 downto 0); d: std_ulogic_vector; e: std_ulogic_vector)
        return std_ulogic_vector is
        variable result: std_ulogic_vector(7 downto 0);
    begin
        case sel is
            when "00" =>
                result := d;
            when "01" =>
                result := d(7) & e(7) & d(5) & e(5) & d(3) & e(3) & d(1) & e(1);
            when "10" =>
                result := d(7) & e(7) & e(7) & e(7) & d(3) & e(3) & e(3) & e(3);
            when others =>
                result := (7 => d(7), others => e(7));
        end case;
        return result;
    end;

begin

    -- Data path

    lenm1 <= std_ulogic_vector(unsigned(e_in.data_len(2 downto 0)) - 1);
    -- compute log_2(data_len), knowing data_len is one-hot
    log_len(1) <= e_in.data_len(3) or e_in.data_len(2);
    log_len(0) <= e_in.data_len(3) or e_in.data_len(1);

    -- vperm
    perm_data <= vst.a0 & a_in & vst.b0 & b_in;
    vperm: for i in 0 to 7 generate
        vperm_result(i*8 + 7 downto i*8) <=
            perm_data(to_integer(unsigned(vst.perm_sel(i*8 + 4 downto i*8))) * 8 + 7 downto
                      to_integer(unsigned(vst.perm_sel(i*8 + 4 downto i*8))) * 8);
    end generate;

    -- vgbbd
    vgbbd: for i in 0 to 7 generate
        vgbbd_i: for j in 0 to 7 generate
            vgbbd_result(i * 8 + j) <= b_in(j * 8 + i);
        end generate;
    end generate;

    -- vpbermq
    vbpermq: for i in 0 to 7 generate
        vbperm_byte(i) <= vperm_result(i * 8 + to_integer(unsigned(not vst.vbp_sel(i * 4 + 2 downto i * 4)))) and
                          not vst.vbp_sel(i * 4 + 3);
    end generate;
    gather_res <= vgbbd_result when e_in.insn(6) = '0'
                  else 64x"0" when vec_in_progress = '1'
                  else 48x"0" & vbperm_byte & vst.vbpermq;

    -- mfvscr/mfvsr*/mtvsr*
    mtvsr_a(31 downto 0) <= a_in(31 downto 0);
    mtvsr_a(63 downto 32) <= a_in(63 downto 32) when e_in.is_32bit = '0'
                             else a_in(31 downto 0) when e_in.insn(9) = '1'
                             else (63 downto 32 => (a_in(31) and e_in.sign_extend));
    mfvsr_c(31 downto 0) <= c_in(31 downto 0);
    mfvsr_c(63 downto 32) <= c_in(63 downto 32) when e_in.is_32bit = '0'
                             else (others => '0');
    move_sel <= "00" when e_in.insn(26) = '0'
                else "01" when e_in.insn(8) = '0'
                else "10" when e_in.second = '0'
                else "00" when e_in.insn(9) = '0'
                else "11" when e_in.insn(6) = '1'
                else "10";
    vscr_enable <= not e_in.insn(26) and e_in.second;
    with move_sel select move_result <=
        -- mfvscr and mtvsr{d,wa,wz} low DW = zero
        47x"0" & (vst.ni and vscr_enable) & 15x"0" & (vst.sat and vscr_enable) when "00",
        -- mfvsr* (not doubled)
        mfvsr_c when "01",
        -- mtvsr* high doubleword, mtvsrws low DW
        mtvsr_a when "10",
        -- mtvsrdd low doubleword
        b_in when others;

    -- vector arithmetic
    is_subtract <= e_in.insn(10);
    -- vadduqm, vsubuqm use vst.carry; note these are done LS then MS
    cin <= vst.carry when e_in.second = '1' and e_in.insn(9 downto 6) = "0100"
           else is_subtract;
    seg_addr: for i in 0 to 7 generate
        vop_a(i * 9 + 7 downto i * 9) <= a_in(i * 8 + 7 downto i * 8);
        vop_b(i * 9 + 7 downto i * 9) <= b_in(i * 8 + 7 downto i * 8) xor
                                         (7 downto 0 => is_subtract);
        -- this tests (7 - i) mod data_len = 0, i.e. it
        -- is 1 for the leftmost byte of each element
        addr_seg(i) <= not (or (lenm1 and not std_ulogic_vector(to_unsigned(i, 3))));
        vop_a(i * 9 + 8) <= cin or not addr_seg(i);
        vop_b(i * 9 + 8) <= cin and addr_seg(i);
    end generate;
    vsum <= std_ulogic_vector(unsigned(vop_a) + unsigned(vop_b) + cin);
    -- Do overflow detection for saturation
    -- We abuse the e_in.sign_extend flag as a indication of which
    -- instructions do saturation.
    ovf_detect: for i in 0 to 7 generate
        -- unsigned overflow: carry=1 for add, carry=0 for sub
        uovf_hi(i) <= not is_subtract and vsum(i * 9 + 8) and not e_in.is_signed;
        uovf_lo(i) <= is_subtract and not vsum(i * 9 + 8) and not e_in.is_signed;
        -- signed overflow: if result sign /= both operand signs
        sovf_hi(i) <= not vop_a(i * 9 + 7) and not vop_b(i * 9 + 7) and vsum(i * 9 + 7) and e_in.is_signed;
        sovf_lo(i) <= vop_a(i * 9 + 7) and vop_b(i * 9 + 7) and not vsum(i * 9 + 7) and e_in.is_signed;
    end generate;
    byte_ovf <= uovf_hi or uovf_lo or sovf_hi or sovf_lo;
    satb0 <= sovf_hi or uovf_hi;
    satb7 <= sovf_lo or uovf_hi;
    overflow <= spreadbits(log_len, byte_ovf, byte_ovf) and (7 downto 0 => e_in.sign_extend);
    sat_msb  <= spreadbits(log_len, satb7, satb0);
    sat_lsb  <= spreadbits(log_len, satb0, satb0);
    -- generate the output
    sum_output: for i in 0 to 7 generate
        varith_res(i * 8 + 7 downto i * 8) <= vsum(i * 9 + 7 downto i * 9) when overflow(i) = '0' else
                                              sat_msb(i) & (6 downto 0 => sat_lsb(i));
    end generate;

    -- Final result mux
    with sub_select select vec_result <=
        varith_res   when "000",
        lvs_result   when "001",
        cmp_result   when "010",
        log_result   when "011",
        move_result  when "100",
        gather_res   when "101",
        sum_result   when "110",
        vperm_result when others;

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
        variable all0, all1   : std_ulogic;
        variable cmpeq        : byte_comparison_t;
        variable cmpgt        : byte_comparison_t;
        variable cmpgtu       : byte_comparison_t;
        variable cmpaz        : byte_comparison_t;
        variable cmpbz        : byte_comparison_t;
        variable bv           : boolean;
        variable byte         : std_ulogic_vector(7 downto 0);
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
        variable is_left_sh   : std_ulogic;
        variable shift_whole  : std_ulogic;
        variable is_empty     : std_ulogic;
        variable right_sel    : std_ulogic_vector(1 downto 0);
        variable leftmost     : std_ulogic;
        variable rightmost    : std_ulogic;
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
                is_left_sh := not (is_right_sh or is_rotate);
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
                end if;
                v.vs_ext_r := a_in(7 downto 0);
                v.vs_ext_l := a_in(63 downto 56);
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
                    leftmost := '0';
                    rightmost := '0';
                    if is_right_sh = '1' then
                        bsh := std_ulogic_vector(- signed(bsh));
                        if (std_ulogic_vector(to_unsigned(i + 1, 3)) and lenm1) = "000" then
                            -- leftmost byte of element
                            leftmost := '1';
                        end if;
                        right_sel := "00";
                    else
                        if (std_ulogic_vector(to_unsigned(i, 3)) and lenm1) = "000" and
                            (is_rotate or (shift_whole and e_in.second)) = '0' then
                            rightmost := '1';
                        end if;
                        right_sel := log_len;
                    end if;

                    if is_right_sh = '0' then
                        shift_in(15 downto 8) := a_in(k + 7 downto k);
                    elsif i < 7 and leftmost = '0' then
                        shift_in(15 downto 8) := a_in(k + 15 downto k + 8);
                    elsif i = 7 and shift_whole = '1' and e_in.second = '1' then
                        shift_in(15 downto 8) := vst.vs_ext_r;
                    else
                        shift_in(15 downto 8) := (others => elt_sign);
                    end if;

                    shift_in(7 downto 0) := (others => '0');
                    case right_sel is
                        when "00" =>
                            shift_in(7 downto 0) := a_in(k + 7 downto k);
                        when "01" =>
                            if (i mod 2) = 0 then
                                shift_in(7 downto 0) := a_in(k + 15 downto k + 8);
                            else
                                shift_in(7 downto 0) := a_in(k - 1 downto k - 8);
                            end if;
                        when "10" =>
                            if (i mod 4) = 0 then
                                shift_in(7 downto 0) := a_in(k + 31 downto k + 24);
                            else
                                shift_in(7 downto 0) := a_in(k - 1 downto k - 8);
                            end if;
                        when others =>
                            if i = 0 then
                                if shift_whole = '1' and e_in.second = '1' then
                                    shift_in(7 downto 0) := vst.vs_ext_l;
                                else
                                    shift_in(7 downto 0) := a_in(63 downto 56);
                                end if;
                            else
                                shift_in(7 downto 0) := a_in(k - 1 downto k - 8);
                            end if;
                    end case;
                    if rightmost = '1' then
                        shift_in(7 downto 0) := (others => '0');
                    end if;
                    if is_empty = '1' then
                        a_sh(k + 7 downto k) := (others => elt_sign);
                    elsif shift(2 downto 0) /= "000" then
                        n := to_integer(unsigned(bsh));
                        a_sh(k + 7 downto k) := shift_in(15 - n downto 8 - n);
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

        cmp_result <= (others => '0');
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
                        cmp_result(k + 7 downto k) <= x"ff";
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
                        cmp_result(k + 7 downto k) <= x"ff";
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
                        cmp_result(k + 7 downto k) <= x"ff";
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
                        cmp_result(k + 15 downto k) <= x"ffff";
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
                        cmp_result(k + 15 downto k) <= x"ffff";
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
                        cmp_result(k + 15 downto k) <= x"ffff";
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
                        cmp_result(k + 31 downto k) <= x"ffffffff";
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
                        cmp_result(k + 31 downto k) <= x"ffffffff";
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
                        cmp_result(k + 31 downto k) <= x"ffffffff";
                        all0 := '0';
                    else
                        all1 := '0';
                    end if;
                end loop;
            when "00111" =>
                -- vcmpequd
                if cmpeq(0) and cmpeq(1) and cmpeq(2) and cmpeq(3) and
                    cmpeq(4) and cmpeq(5) and cmpeq(6) and cmpeq(7) then
                    cmp_result <= (others => '1');
                    all0 := '0';
                else
                    all1 := '0';
                end if;
            when "10000" =>
                -- vcmpgtub
                for i in 0 to 7 loop
                    k := i * 8;
                    if cmpgtu(i) then
                        cmp_result(k + 7 downto k) <= x"ff";
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
                        cmp_result(k + 15 downto k) <= x"ffff";
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
                        cmp_result(k + 31 downto k) <= x"ffffffff";
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
                    cmp_result <= (others => '1');
                    all0 := '0';
                else
                    all1 := '0';
                end if;
            when "11000" =>
                -- vcmpgtsb
                for i in 0 to 7 loop
                    k := i * 8;
                    if cmpgt(i) then
                        cmp_result(k + 7 downto k) <= x"ff";
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
                        cmp_result(k + 15 downto k) <= x"ffff";
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
                        cmp_result(k + 31 downto k) <= x"ffffffff";
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
                    cmp_result <= (others => '1');
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
            lvs_result(k + 7 downto k) <= std_ulogic_vector(sum + to_unsigned(7 - i, 8));
        end loop;

        -- compute vector logical result
        if e_in.insn(5) = '1' then
            -- vsel
            log_result <= (a_in and not c_in) or (b_in and c_in);
        else
            case e_in.insn(8 downto 6) is
                when "000" =>
                    log_result <= a_in and b_in;
                when "001" =>
                    log_result <= a_in and not b_in;
                when "010" =>
                    log_result <= a_in or b_in;
                when "011" =>
                    log_result <= a_in xor b_in;
                when "100" =>
                    log_result <= not (a_in or b_in);
                when "101" =>
                    log_result <= a_in or not b_in;
                when "110" =>
                    log_result <= not (a_in and b_in);
                when others =>
                    log_result <= a_in xnor b_in;
            end case;
        end if;

        if e_in.valid = '1' then
            v.vbpermq := vbperm_byte;
        end if;

        -- execute mtvscr
        if vec_valid = '1' and e_in.insn_type = OP_MTVSCR and e_in.second = '1' then
            v.ni := b_in(16);
            v.sat := b_in(0);
        end if;

        -- vector arithmetic
        v.carry := vsum(71);
        if e_in.insn_type = OP_VARITH and vec_valid = '1' and overflow /= x"00" then
            v.sat := '1';
        end if;

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
            sum_result(63 downto 32) <= x"00000000";
            if e_in.second = '1' or e_in.insn(8) = '0' then
                total := std_ulogic_vector(unsigned(word2(33) & word2) +
                                           unsigned(word_sum(33) & word_sum));
                -- work out whether to saturate
                if total(34 downto 31) = "0000" or total(34 downto 31) = "1111" then
                    sum_result(31 downto 0) <= total(31 downto 0);
                else
                    if e_in.insn_type = OP_VSUM and vec_valid = '1' then
                        v.sat := '1';
                    end if;
                    if total(34) = '0' then
                        sum_result(31 downto 0) <= x"7fffffff";
                    else
                        sum_result(31 downto 0) <= x"80000000";
                    end if;
                end if;
            else
                sum_result(31 downto 0) <= x"00000000";
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
                    sum_result(k + 31 downto k) <= sum2(31 downto 0);
                else
                    if e_in.insn_type = OP_VSUM and vec_valid = '1' then
                        v.sat := '1';
                    end if;
                    if e_in.is_signed = '0' then
                        sum_result(k + 31 downto k) <= x"ffffffff";
                    elsif sum2(32) = '0' then
                        sum_result(k + 31 downto k) <= x"7fffffff";
                    else
                        sum_result(k + 31 downto k) <= x"80000000";
                    end if;
                end if;
            end loop;
        end if;

        -- update state
        vst_in <= v;
    end process;
end architecture behaviour;
