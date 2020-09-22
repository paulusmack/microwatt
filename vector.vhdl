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
        e_in            : in  Execute1ToVectorType;
        e_out           : out VectorToExecute1Type;
        w_out           : out VectorToWritebackType
        );
end entity vector_unit;

architecture behaviour of vector_unit is
    
    -- State for vector instructions
    type vec_state is record
        a0       : std_ulogic_vector(63 downto 0);
        b0       : std_ulogic_vector(63 downto 0);
        a1       : std_ulogic_vector(63 downto 0);
        b1       : std_ulogic_vector(63 downto 0);
        perm_sel : std_ulogic_vector(63 downto 0);
        result   : std_ulogic_vector(63 downto 0);
        writes   : std_ulogic;
        wr_reg   : gspr_index_t;
        wr_cr    : std_ulogic;
        op       : insn_type_t;
        rsel     : std_ulogic_vector(2 downto 0);
        itag     : instr_tag_t;
        part1    : std_ulogic;
        part2    : std_ulogic;
        ni       : std_ulogic;          -- non-IEEE mode
        sat      : std_ulogic;          -- saturation flag
        cmp_bits : std_ulogic_vector(7 downto 0);
        all0     : std_ulogic;
        all1     : std_ulogic;
        e        : VectorToExecute1Type;
        w        : VectorToWritebackType;
    end record;
    constant vec_state_init : vec_state := (e => VectorToExecute1Init, w => VectorToWritebackInit,
                                            writes => '0', wr_reg => (others => '0'), wr_cr => '0',
                                            op => OP_ILLEGAL, rsel => "000", itag => instr_tag_init,
                                            part1 => '0', part2 => '0', ni => '0', sat => '0',
                                            cmp_bits => x"00", all0 => '0', all1 => '0',
                                            others => (others => '0'));

    signal vst, vst_in : vec_state;

    signal a_in         : std_ulogic_vector(63 downto 0);
    signal b_in         : std_ulogic_vector(63 downto 0);
    signal c_in         : std_ulogic_vector(63 downto 0);
    signal a1_in        : std_ulogic_vector(63 downto 0);
    signal b1_in        : std_ulogic_vector(63 downto 0);
    signal vperm_result : std_ulogic_vector(63 downto 0);
    signal vscr_result  : std_ulogic_vector(63 downto 0);
    signal vcmp_result  : std_ulogic_vector(63 downto 0);
    signal perm_data    : std_ulogic_vector(255 downto 0);
    signal vec_result   : std_ulogic_vector(63 downto 0);
    signal vec_cr6      : std_ulogic_vector(3 downto 0);
    signal cmp_bits     : std_ulogic_vector(7 downto 0);

    signal cmpeq        : std_ulogic_vector(7 downto 0);
    signal cmpgt        : std_ulogic_vector(7 downto 0);
    signal cmpgtu       : std_ulogic_vector(7 downto 0);
    signal cmpaz        : std_ulogic_vector(7 downto 0);
    signal cmpbz        : std_ulogic_vector(7 downto 0);
    signal hcmpeq       : std_ulogic_vector(3 downto 0);
    signal hcmpgt       : std_ulogic_vector(3 downto 0);
    signal hcmpgtu      : std_ulogic_vector(3 downto 0);
    signal hcmpaz       : std_ulogic_vector(3 downto 0);
    signal hcmpbz       : std_ulogic_vector(3 downto 0);
    signal wcmpeq       : std_ulogic_vector(1 downto 0);
    signal wcmpgt       : std_ulogic_vector(1 downto 0);
    signal wcmpgtu      : std_ulogic_vector(1 downto 0);
    signal wcmpaz       : std_ulogic_vector(1 downto 0);
    signal wcmpbz       : std_ulogic_vector(1 downto 0);
    signal dcmpeq       : std_ulogic;
    signal dcmpgt       : std_ulogic;
    signal dcmpgtu      : std_ulogic;
    signal dcmpaz       : std_ulogic;
    signal dcmpbz       : std_ulogic;

    type byte_comparison_t is array(0 to 7) of boolean;

    -- 2x comparison reduction functions
    function reduce_eq(eq: std_ulogic_vector) return std_ulogic_vector is
        variable result: std_ulogic_vector(eq'length / 2 - 1 downto 0);
    begin
        for i in 0 to result'left loop
            result(i) := eq(2*i + 1) and eq(2*i);
        end loop;
        return result;
    end;
    function reduce_gtu(gtu: std_ulogic_vector; eq: std_ulogic_vector) return std_ulogic_vector is
        variable result: std_ulogic_vector(gtu'length / 2 - 1 downto 0);
    begin
        for i in 0 to result'left loop
            result(i) := gtu(2*i + 1) or (eq(2*i + 1) and gtu(2*i));
        end loop;
        return result;
    end;
    function reduce_gt(gt: std_ulogic_vector; eq: std_ulogic_vector;
                       gtu: std_ulogic_vector) return std_ulogic_vector is
        variable result: std_ulogic_vector(gt'length / 2 - 1 downto 0);
    begin
        for i in 0 to result'left loop
            result(i) := gt(2*i + 1) or (eq(2*i + 1) and gtu(2*i));
        end loop;
        return result;
    end;

    -- Expand each bit of a vector to 2 consecutive bits
    function vexpand2(vec: std_ulogic_vector(3 downto 0)) return std_ulogic_vector is
        variable result: std_ulogic_vector(7 downto 0);
    begin
        for i in 0 to 3 loop
            result(2*i + 1 downto 2*i) := (others => vec(i));
        end loop;
        return result;
    end;

    -- Expand each bit of a vector to 4 consecutive bits
    function vexpand4(vec: std_ulogic_vector(1 downto 0)) return std_ulogic_vector is
        variable result: std_ulogic_vector(7 downto 0);
    begin
        for i in 0 to 1 loop
            result(4*i + 3 downto 4*i) := (others => vec(i));
        end loop;
        return result;
    end;

begin

    -- Data path
    a_in <= e_in.vra;
    b_in <= e_in.vrb;
    c_in <= e_in.vrc;

    a1_in <= a_in when vst.part1 = '1' else vst.a1;
    b1_in <= b_in when vst.part1 = '1' else vst.b1;

    -- do comparisons for vcmp*
    byte_cmp: for i in 0 to 7 generate
        cmpeq(i) <= '1' when unsigned(a_in(i*8 + 7 downto i*8)) = unsigned(b_in(i*8 + 7 downto i*8)) else '0';
        cmpgt(i) <= '1' when signed(a_in(i*8 + 7 downto i*8)) > signed(b_in(i*8 + 7 downto i*8)) else '0';
        cmpgtu(i) <= '1' when unsigned(a_in(i*8 + 7 downto i*8)) > unsigned(b_in(i*8 + 7 downto i*8)) else '0';
        cmpaz(i) <= '1' when a_in(i*8 + 7 downto i*8) = x"00" else '0';
        cmpbz(i) <= '1' when b_in(i*8 + 7 downto i*8) = x"00" else '0';
    end generate;
    -- Work out half-word comparison results
    hcmpeq <= reduce_eq(cmpeq);
    hcmpgt <= reduce_gt(cmpgt, cmpeq, cmpgtu);
    hcmpgtu <= reduce_gtu(cmpgtu, cmpeq);
    hcmpaz <= reduce_eq(cmpaz);
    hcmpbz <= reduce_eq(cmpbz);
    -- Work out word comparison results
    wcmpeq <= reduce_eq(hcmpeq);
    wcmpgt <= reduce_gt(hcmpgt, hcmpeq, hcmpgtu);
    wcmpgtu <= reduce_gtu(hcmpgtu, hcmpeq);
    wcmpaz <= reduce_eq(hcmpaz);
    wcmpbz <= reduce_eq(hcmpbz);
    -- Work out doubleword comparison results
    dcmpeq <= reduce_eq(wcmpeq)(0);
    dcmpgt <= reduce_gt(wcmpgt, wcmpeq, wcmpgtu)(0);
    dcmpgtu <= reduce_gtu(wcmpgtu, wcmpeq)(0);
    dcmpaz <= reduce_eq(wcmpaz)(0);
    dcmpbz <= reduce_eq(wcmpbz)(0);

    -- vcmp* result
    with e_in.insn(9 downto 6) & e_in.insn(0) select cmp_bits <=
        -- vcmpequb
        cmpeq when "00000",
        -- vcmpneb
        not cmpeq when "00001",
        -- vcmpnezb
        not cmpeq or cmpaz or cmpbz when "01001",
        -- vcmpequh
        vexpand2(hcmpeq) when "00010",
        -- vcmpneh
        vexpand2(not hcmpeq) when "00011",
        -- vcmpnezh
        vexpand2(not hcmpeq or hcmpaz or hcmpbz) when "01011",
        -- vcmpequw
        vexpand4(wcmpeq) when "00100",
        -- vcmpnew
        vexpand4(not wcmpeq) when "00101",
        -- vcmpnezw
        vexpand4(not wcmpeq or wcmpaz or wcmpbz) when "01101",
        -- vcmpequd
        (others => dcmpeq) when "00111",
        -- vcmpgtub
        cmpgtu when "10000",
        -- vcmpgtuh
        vexpand2(hcmpgtu) when "10010",
        -- vcmpgtuw
        vexpand4(wcmpgtu) when "10100",
        -- vcmpgtud
        (others => dcmpgtu) when "10111",
        -- vcmpgtsb
        cmpgt when "11000",
        -- vcmpgtsh
        vexpand2(hcmpgt) when "11010",
        -- vcmpgtsw
        vexpand4(wcmpgt) when "11100",
        -- vcmpgtsd
        (others => dcmpgt) when "11111",
        (others => '0') when others;

    vcmp_expand: for i in 0 to 7 generate
        vcmp_result(i*8 + 7 downto i*8) <= (others => vst.cmp_bits(i));
    end generate;

    -- vperm
    perm_data <= vst.a0 & a1_in & vst.b0 & b1_in;
    vperm: for i in 0 to 7 generate
        vperm_result(i*8 + 7 downto i*8) <=
            perm_data(to_integer(unsigned(vst.perm_sel(i*8 + 4 downto i*8))) * 8 + 7 downto
                      to_integer(unsigned(vst.perm_sel(i*8 + 4 downto i*8))) * 8);
    end generate;

    with vst.rsel select vec_result <=
        vscr_result  when "000",
        vst.result   when "001",
        vcmp_result  when "010",
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
        variable v    : vec_state;
        variable k, m : integer;
        variable b    : std_ulogic;
        variable sum  : unsigned(7 downto 0);
        variable lvs_result : std_ulogic_vector(63 downto 0);
        variable log_result : std_ulogic_vector(63 downto 0);
        variable move_result: std_ulogic_vector(63 downto 0);
        variable all0, all1 : std_ulogic;
    begin
        v := vst;
        v.e.busy := '0';

        if e_in.valid = '1' then
            v.writes := e_in.write_reg_enable;
            v.wr_reg := e_in.write_reg;
            v.wr_cr := e_in.output_cr;
            v.itag := e_in.instr_tag;
        end if;

        v.part2 := '0';
        if vst.part2 = '1' then
            v.e.in_progress := '0';
        end if;
        if e_in.valid = '1' then
            if e_in.second = '0' then
                v.part1 := '1';
                v.e.in_progress := '1';
                v.rsel := e_in.result_sel;
            else
                v.part1 := '0';
                v.part2 := '1';
            end if;
        end if;

        if e_in.valid = '1' then
            if e_in.second = '0' then
                v.a0 := a_in;
                v.b0 := b_in;
            else
                v.a1 := a_in;
                v.b1 := b_in;
            end if;
        end if;

        -- Compute permutation vector v.perm_sel
        if e_in.valid = '1' then
            case e_in.insn_type is
                when OP_VPERM =>
                    -- OP_VPERM, columns 2b, 3b
                    if e_in.insn(4) = '0' then
                        -- vperm
                        v.perm_sel := not c_in;
                    else
                        -- vpermr
                        v.perm_sel := c_in;
                    end if;
                when OP_VPACK =>
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
                when OP_XPERM =>
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
                when others =>
                    v.perm_sel := (others => '0');
            end case;
        end if;

        -- CR6 result for vcmp*.
        if e_in.valid = '1' then
            v.cmp_bits := cmp_bits;
        end if;
        all0 := not (or (vst.cmp_bits));
        all1 := (and (vst.cmp_bits));
        if vst.part1 = '1' then
            v.all0 := all0;
            v.all1 := all1;
        end if;
        vec_cr6 <= (all1 and vst.all1) & '0' & (all0 and vst.all0) & '0';

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
        vscr_result <= (16 => vst.ni and vst.part2,
                        0 => vst.sat and vst.part2, others => '0');

        -- compute vector logical result
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

        -- mtvsr* result (mfvsr* is done in execute1)
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
        if e_in.is_32bit = '1' then
            if e_in.insn(9) = '1' then
                -- mtvsrws
                move_result(63 downto 32) := move_result(31 downto 0);
            else
                b := e_in.sign_extend and move_result(31);
                move_result(63 downto 32) := (others => b);
            end if;
        end if;

        -- Stash away result for ops which compute their result in the first cycle
        if e_in.valid = '1' then
            case e_in.sub_select is
                when "000" =>
                    v.result := lvs_result;
                when "001" =>
                    v.result := log_result;
                when others =>
                    v.result := move_result;
            end case;
        end if;

        -- execute mtvscr
        if e_in.valid = '1' and e_in.insn_type = OP_MTVSCR and e_in.second = '1' then
            v.ni := b_in(16);
            v.sat := b_in(0);
        end if;

        -- Set up outputs to writeback
        v.w.valid := (vst.part1 and e_in.valid) or vst.part2;
        v.w.instr_tag := vst.itag;
        v.w.write_enable := v.w.valid and vst.writes;
        v.w.write_reg := vst.wr_reg;
        v.w.write_data := vec_result;

        -- write back CR6 result on the second half
        v.w.write_cr_enable := vst.part2 and vst.wr_cr;
        v.w.write_cr_mask := num_to_fxm(6);
        v.w.write_cr_data := x"000000" & vec_cr6 & x"0";

        w_out <= vst.w;
        e_out <= vst.e;

        -- update state
        vst_in <= v;
    end process;
end architecture behaviour;
