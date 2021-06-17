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
        a0           : std_ulogic_vector(63 downto 0);
        b0           : std_ulogic_vector(63 downto 0);
        a1           : std_ulogic_vector(63 downto 0);
        b1           : std_ulogic_vector(63 downto 0);
        perm_sel     : std_ulogic_vector(63 downto 0);
        result       : std_ulogic_vector(63 downto 0);
        writes       : std_ulogic;
        wr_reg       : gspr_index_t;
        wr_cr        : std_ulogic;
        op           : insn_type_t;
        rsel         : std_ulogic_vector(2 downto 0);
        itag         : instr_tag_t;
        part1        : std_ulogic;
        part2        : std_ulogic;
        ni           : std_ulogic;          -- non-IEEE mode
        sat          : std_ulogic;          -- saturation flag
        cmp_bits     : std_ulogic_vector(7 downto 0);
        all0         : std_ulogic;
        all1         : std_ulogic;
        vs_ext_l     : std_ulogic_vector(7 downto 0);
        vs_ext_r     : std_ulogic_vector(7 downto 0);
        vbpermq      : std_ulogic_vector(7 downto 0);
        vbp_sel      : std_ulogic_vector(31 downto 0);
        carry        : std_ulogic;
        oshift       : unsigned(3 downto 0);
        asum0, asum1 : signed(32 downto 0);
        bsum0, bsum1 : signed(33 downto 0);
        vsum         : std_ulogic_vector(71 downto 0);
        is_signed    : std_ulogic;
        is_subtract  : std_ulogic;
        is_sat       : std_ulogic;
        vop_sign_a   : std_ulogic_vector(7 downto 0);
        vop_sign_b   : std_ulogic_vector(7 downto 0);
        data_len     : std_ulogic_vector(3 downto 0);
        log_len      : std_ulogic_vector(1 downto 0);
        insn         : std_ulogic_vector(31 downto 0);
        do_vsum      : std_ulogic;
        sum_across   : std_ulogic;
        e            : VectorToExecute1Type;
        w            : VectorToWritebackType;
    end record;
    constant vec_state_init : vec_state := (e => VectorToExecute1Init, w => VectorToWritebackInit,
                                            writes => '0', wr_reg => (others => '0'), wr_cr => '0',
                                            op => OP_ILLEGAL, rsel => "000", itag => instr_tag_init,
                                            part1 => '0', part2 => '0', ni => '0', sat => '0',
                                            cmp_bits => x"00", all0 => '0', all1 => '0',
                                            vs_ext_l => x"00", vs_ext_r => x"00",
                                            vbpermq => x"00", vbp_sel => (others => '0'),
                                            carry => '0', oshift => "0000",
                                            asum0 => (others => '0'), asum1 => (others => '0'),
                                            bsum0 => (others => '0'), bsum1 => (others => '0'),
                                            vsum => (others => '0'),
                                            is_signed => '0', is_subtract => '0', is_sat => '0',
                                            vop_sign_a => x"00", vop_sign_b => x"00",
                                            data_len => "0000", log_len => "00",
                                            insn => 32x"0", do_vsum => '0', sum_across => '0',
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
    signal vsum_result  : std_ulogic_vector(63 downto 0);
    signal sat_result   : std_ulogic_vector(63 downto 0);
    signal vclsb_result : std_ulogic_vector(63 downto 0);
    signal vbpermq_res  : std_ulogic_vector(63 downto 0);
    signal vbperm_byte  : std_ulogic_vector(7 downto 0);
    signal perm_data    : std_ulogic_vector(255 downto 0);
    signal vec_result   : std_ulogic_vector(63 downto 0);
    signal vec_cr6      : std_ulogic_vector(3 downto 0);
    signal cmp_bits     : std_ulogic_vector(7 downto 0);
    signal maxbits      : std_ulogic_vector(7 downto 0);
    signal lsbs         : std_ulogic_vector(16 downto 0);

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

    signal byte_ovf     : std_ulogic_vector(7 downto 0);
    signal sovf_lo      : std_ulogic_vector(7 downto 0);
    signal sovf_hi      : std_ulogic_vector(7 downto 0);
    signal uovf_lo      : std_ulogic_vector(7 downto 0);
    signal uovf_hi      : std_ulogic_vector(7 downto 0);
    signal arith_ovf    : std_ulogic_vector(7 downto 0);
    signal arith_satm   : std_ulogic_vector(7 downto 0);
    signal arith_satl   : std_ulogic_vector(7 downto 0);
    signal satb0        : std_ulogic_vector(7 downto 0);
    signal satb7        : std_ulogic_vector(7 downto 0);

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

    function add4bytes(a: std_ulogic_vector(31 downto 0); is_signed: std_ulogic)
        return std_ulogic_vector is
        variable byte0, byte1 : std_ulogic_vector(8 downto 0);
        variable byte2, byte3 : std_ulogic_vector(8 downto 0);
        variable bsum0, bsum1 : std_ulogic_vector(8 downto 0);
        variable byte_sum     : std_ulogic_vector(9 downto 0);
    begin
        -- sum across groups of 4 bytes (signed or unsigned)
        byte0 := (is_signed and a(7)) & a(7 downto 0);
        byte1 := (is_signed and a(15)) & a(15 downto 8);
        bsum0 := std_ulogic_vector(unsigned(byte0) + unsigned(byte1));
        byte2 := (is_signed and a(23)) & a(23 downto 16);
        byte3 := (is_signed and a(31)) & a(31 downto 24);
        bsum1 := std_ulogic_vector(unsigned(byte2) + unsigned(byte3));
        byte_sum := std_ulogic_vector(unsigned((is_signed and bsum0(8)) & bsum0) +
                                      unsigned((is_signed and bsum1(8)) & bsum1));
        return (is_signed and byte_sum(9)) & byte_sum;
    end;

    function add2halves(a: std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
        variable half0, half1 : std_ulogic_vector(16 downto 0);
        variable half_sum     : std_ulogic_vector(16 downto 0);
    begin
        -- sum across half-words, always signed
        half0 := a(15) & a(15 downto 0);
        half1 := a(31) & a(31 downto 16);
        half_sum := std_ulogic_vector(unsigned(half0) + unsigned(half1));
        return half_sum;
    end;

    function saturate32(total: signed(34 downto 0); is_signed: std_ulogic)
        return std_ulogic_vector is
    begin
        if is_signed = '0' then
            if total(34 downto 32) /= "000" then
                return 33x"1ffffffff";
            end if;
        else
            if total(34 downto 31) /= "0000" and total(34 downto 31) /= "1111" then
                if total(34) = '0' then
                    return 33x"17fffffff";
                else
                    return 33x"180000000";
                end if;
            end if;
        end if;
        return '0' & std_ulogic_vector(total(31 downto 0));
    end;

    function bsel(sel: std_ulogic; b0, b1: std_ulogic) return std_ulogic is
    begin
        return (not sel and b0) or (sel and b1);
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

    -- vmin/vmax selection
    with e_in.insn(8 downto 6) select maxbits <=
        -- vmaxub, vminub
        cmpgtu when "000",
        -- vmaxuh, vimnuh
        vexpand2(hcmpgtu) when "001",
        -- vmaxuw, vminuw
        vexpand4(wcmpgtu) when "010",
        -- vmaxud, vminud
        (others => dcmpgtu) when "011",
        -- vmaxsb, vminsb
        cmpgt when "100",
        -- vmaxsh, vminsh
        vexpand2(hcmpgt) when "101",
        -- vmaxsw, vminsw
        vexpand4(wcmpgt) when "110",
        -- vmaxsd, vminsd
        (others => dcmpgt) when others;

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

    -- vbpermq
    vbpermq: for i in 0 to 7 generate
        vbperm_byte(i) <= vperm_result(i*8 + to_integer(unsigned(not vst.vbp_sel(i*4 + 2 downto i*4)))) and
                          not vst.vbp_sel(i*4 + 3);
    end generate;
    vbpermq_res <= 48x"0" & vbperm_byte & vst.vbpermq when vst.part2 = '1'
                   else 64x"0";

    -- Detect overflow in segmented adder result
    ovf_detect: for i in 0 to 7 generate
        -- unsigned overflow: carry=1 for add, carry=0 for sub
        uovf_hi(i) <= not vst.is_subtract and vst.vsum(i*9 + 8) and not vst.is_signed and vst.is_sat;
        uovf_lo(i) <= vst.is_subtract and not vst.vsum(i*9 + 8) and not vst.is_signed and vst.is_sat;
        -- signed overflow: if result sign /= both operand signs
        sovf_hi(i) <= not vst.vop_sign_a(i) and not vst.vop_sign_b(i) and vst.vsum(i*9 + 7) and
                      vst.is_signed and vst.is_sat;
        sovf_lo(i) <= vst.vop_sign_a(i) and vst.vop_sign_b(i) and not vst.vsum(i*9 + 7) and
                      vst.is_signed and vst.is_sat;
    end generate;
    byte_ovf <= uovf_hi or uovf_lo or sovf_hi or sovf_lo;
    satb0 <= sovf_hi or uovf_hi;
    satb7 <= sovf_lo or uovf_hi;
    arith_ovf <= spreadbits(vst.log_len, byte_ovf, byte_ovf) and (7 downto 0 => vst.is_sat);
    arith_satm <= spreadbits(vst.log_len, satb7, satb0);
    arith_satl <= spreadbits(vst.log_len, satb0, satb0);

    sat_output: for i in 0 to 7 generate
        sat_result(i*8 + 7 downto i*8) <= vst.vsum(i*9 + 7 downto i*9) when arith_ovf(i) = '0' else
                                          arith_satm(i) & (6 downto 0 => arith_satl(i));
    end generate;

    -- vclzlsbb and vctzlsbb
    vlsbs: for i in 0 to 15 generate
        lsbs(i) <= perm_data(i*8) when vst.insn(16) = '1' else perm_data((15-i)*8);
    end generate;
    lsbs(16) <= '1';
    vclsb_result(63 downto 6) <= (others => '0');
    vclsb_result(5 downto 0) <= 6x"0" when vst.part2 = '0' else count_right_zeroes(lsbs);

    with vst.rsel select vec_result <=
        vscr_result  when "000",
        vst.result   when "001",
        vcmp_result  when "010",
        vbpermq_res  when "011",
        sat_result   when "100",
        vclsb_result when "101",
        vsum_result  when "110",
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
        variable sum          : unsigned(7 downto 0);
        variable a_sh         : std_ulogic_vector(63 downto 0);
        variable b_sh         : std_ulogic_vector(63 downto 0);
        variable store_ab0    : std_ulogic;
        variable store_ab1    : std_ulogic;
        variable lvs_result   : std_ulogic_vector(63 downto 0);
        variable log_result   : std_ulogic_vector(63 downto 0);
        variable move_result  : std_ulogic_vector(63 downto 0);
        variable gather_res   : std_ulogic_vector(63 downto 0);
        variable vsel_result  : std_ulogic_vector(63 downto 0);
        variable sum_result   : std_ulogic_vector(63 downto 0);
        variable all0, all1   : std_ulogic;
        variable lenm1        : std_ulogic_vector(2 downto 0);
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
        variable log_len      : std_ulogic_vector(1 downto 0);
        variable right_sel    : std_ulogic_vector(1 downto 0);
        variable leftmost     : std_ulogic;
        variable rightmost    : std_ulogic;
        variable byte         : std_ulogic_vector(7 downto 0);
        variable vop_a        : std_ulogic_vector(71 downto 0);
        variable vop_b        : std_ulogic_vector(71 downto 0);
        variable vsum         : std_ulogic_vector(71 downto 0);
        variable cin          : std_ulogic;
        variable oshift       : unsigned(3 downto 0);
        variable index        : std_ulogic_vector(4 downto 0);
        variable total        : std_ulogic_vector(32 downto 0);
        variable bext0, bext1 : signed(33 downto 0);
        variable bconst       : std_ulogic_vector(4 downto 0);
        variable const_b0     : std_ulogic;
        variable sum_across   : std_ulogic;
        variable idx          : std_ulogic_vector(2 downto 0);
        variable byteno       : unsigned(3 downto 0);
    begin
        v := vst;
        v.e.busy := '0';

        if e_in.valid = '1' then
            v.writes := e_in.write_reg_enable;
            v.wr_reg := e_in.write_reg;
            v.wr_cr := e_in.output_cr;
            v.itag := e_in.instr_tag;
            v.insn := e_in.insn;
            v.data_len := e_in.data_len;
            v.is_signed := e_in.is_signed;
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

        a_sh := a_in;
        b_sh := b_in;
        store_ab0 := e_in.valid and not e_in.second;
        store_ab1 := e_in.valid and e_in.second;
        const_b0 := '0';
        bconst := "00000";
        sum_across := '0';
        v.do_vsum := '0';

        lenm1 := std_ulogic_vector(unsigned(e_in.data_len(2 downto 0)) - 1);
        -- compute log_2(data_len), knowing data_len is one-hot
        log_len(1) := e_in.data_len(3) or e_in.data_len(2);
        log_len(0) := e_in.data_len(3) or e_in.data_len(1);

        -- Compute permutation vector v.perm_sel
        if e_in.valid = '1' then
            v.perm_sel := (others => '0');
            case e_in.insn_type is
                when OP_VPERM =>
                    -- OP_VPERM, columns 2b and 3b for vperm/vpermr
                    -- also xxperm/xxpermr
                    if e_in.insn(31) = '0' then
                        b := e_in.insn(4);      -- vperm[r]
                    else
                        b := e_in.insn(8);      -- xxperm[r]
                    end if;
                    if b = '0' then
                        -- vperm/xxperm
                        v.perm_sel := not c_in;
                    else
                        -- vpermr/xxpermr
                        v.perm_sel := c_in;
                    end if;
                when OP_VMINMAX =>
                    -- OP_VMINMAX, column 02
                    -- e_in.insn(9) is 1 for vmin, 0 for vmax
                    for i in 0 to 7 loop
                        k := i * 8;
                        v.perm_sel(k + 7 downto k) := "000" & (maxbits(i) xor e_in.insn(9)) &
                                                      not e_in.second & std_ulogic_vector(to_unsigned(i, 3));
                    end loop;
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
                when OP_VUNPACK =>
                    -- vupk[hl]s[bhw]
                    -- insn bit 7 = 0 for 'h', 1 for 'l' versions
                    -- 'l' versions are done low dword then high dword so we
                    -- always get the bytes to sign-extend in the first dword
                    for i in 0 to 7 loop
                        k := i * 8;
                        idx := std_ulogic_vector(to_unsigned(i, 3));
                        -- Put sign-extension bits in A operand
                        m := to_integer(unsigned(idx or lenm1)) * 8 + 7;
                        a_sh(k + 7 downto k) := (others => b_in(m));
                        v.perm_sel(k + 7 downto k) := "000" & or (idx and e_in.data_len(2 downto 0)) &
                                                      '1' & (e_in.insn(7) xnor e_in.second) &
                                                      bsel(e_in.data_len(2), idx(2), idx(1)) &
                                                      bsel(e_in.data_len(0), idx(0), idx(1));
                    end loop;
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
                            -- vspltw and xxspltw
                            for i in 0 to 1 loop
                                k := i * 32;
                                v.perm_sel(k + 7 downto k) := "0000" & not e_in.insn(17 downto 16) & "00";
                                v.perm_sel(k + 15 downto k + 8) := "0000" & not e_in.insn(17 downto 16) & "01";
                                v.perm_sel(k + 23 downto k + 16) := "0000" & not e_in.insn(17 downto 16) & "10";
                                v.perm_sel(k + 31 downto k + 24) := "0000" & not e_in.insn(17 downto 16) & "11";
                            end loop;
                        when "01100" =>
                            -- vspltisb
                            bconst := e_in.insn(20 downto 16);
                            const_b0 := '1';
                            v.perm_sel := x"0808080808080808";
                        when "01101" =>
                            -- vspltish
                            bconst := e_in.insn(20 downto 16);
                            const_b0 := '1';
                            v.perm_sel := x"0908090809080908";
                        when "01110" =>
                            -- vspltisw
                            bconst := e_in.insn(20 downto 16);
                            const_b0 := '1';
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
                            -- vmrghw and xxmrghw
                            if e_in.second = '0' then
                                v.perm_sel := x"1f1e1d1c0f0e0d0c";
                            else
                                v.perm_sel := x"1b1a19180b0a0908";
                            end if;
                        when "00110" =>
                            -- vmrglw and xxmrglw
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
                when OP_VSHIFT =>
                    store_ab0 := '1';
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
                when OP_VSHOCT =>
                    -- we do LS then MS because the shift count is in the
                    -- LS half of VRB
                    const_b0 := '1';
                    if e_in.second = '0' then
                        oshift := unsigned(b_in(6 downto 3));
                        v.oshift := oshift;
                    else
                        oshift := vst.oshift;
                    end if;
                    if e_in.insn(6) = '0' then
                        -- vslo
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
                        -- vsro
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
                when OP_VSHOI =>
                    -- vsldoi or xxsldwi (shift by octets immediate)
                    m := 16 - to_integer(unsigned(e_in.insn(9 downto 6)));
                    if e_in.second = '0' then
                        m := m + 8;
                    end if;
                    for i in 0 to 7 loop
                        k := i * 8;
                        v.perm_sel(k + 7 downto k) := "000" & std_ulogic_vector(to_unsigned(m, 5) + to_unsigned(i, 5));
                    end loop;
                when OP_VSUM =>
                    v.do_vsum := '1';
                    if e_in.insn(8 downto 6) = "110" then
                        sum_across := '1';
                    end if;
                when OP_VEXTR =>
                    a_sh := (others => '0');
                    -- top 32 bits of result are always 0
                    v.perm_sel(63 downto 32) := x"1f1f1f1f";
                    if e_in.invert_a = '0' then
                        byteno := unsigned(a_in(3 downto 0));
                    else
                        byteno := unsigned(not a_in(3 downto 0)) - unsigned('0' & lenm1);
                    end if;
                    for i in 0 to 3 loop
                        k := i * 8;
                        if i > to_integer(unsigned(lenm1(1 downto 0))) then
                            v.perm_sel(k + 7 downto k) := x"1f";
                        else
                            v.perm_sel(k + 7 downto k) :=
                                "0000" & std_ulogic_vector(byteno + to_unsigned(i, 4));
                        end if;
                    end loop;
                when others =>
            end case;
        end if;

        if store_ab0 = '1' then
            v.a0 := a_sh;
            if const_b0 = '0' then
                v.b0 := b_sh;
            else
                v.b0 := std_ulogic_vector(resize(signed(bconst), 64));
            end if;
        end if;
        if store_ab1 = '1' then
            v.a1 := a_in;
            v.b1 := b_in;
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

        -- compute vsel result
        vsel_result := (a_in and not c_in) or (b_in and c_in);

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

        -- vgbbd result
        for i in 0 to 7 loop
            for j in 0 to 7 loop
                gather_res(i * 8 + j) := b_in(j * 8 + i);
            end loop;
        end loop;

        -- vector arithmetic
        if e_in.valid = '1' then
            v.is_subtract := e_in.insn(10);
            v.log_len := log_len;
            if e_in.insn_type = OP_VARITH then
                v.is_sat := e_in.sign_extend;
            else
                v.is_sat := '0';
            end if;
        end if;
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
            -- test if (i + 1) mod size = 0
            if (std_ulogic_vector(to_unsigned(i + 1, 3)) and lenm1) = "000" then
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
        if e_in.valid = '1' then
            v.carry := vsum(71);
            -- save full sum and input sign bits for overflow detection
            v.vsum := vsum;
            for i in 0 to 7 loop
                m := i * 9;
                v.vop_sign_a(i) := vop_a(m + 7);
                v.vop_sign_b(i) := vop_b(m + 7);
            end loop;
        end if;

        -- Sum-across logic
        if e_in.valid = '1' then
            v.sum_across := sum_across;

            -- Add two halves of A for vsumsws and vsum2sws
            if e_in.data_len(2) = '1' then
                v.asum0 := resize(signed(a_in(31 downto 0)), 33) +
                           resize(signed(a_in(63 downto 32)), 33);
                v.asum1 := 33x"0";
            elsif e_in.data_len(1) = '1' then
                v.asum0 := resize(signed(add2halves(a_in(31 downto 0))), 33);
                v.asum1 := resize(signed(add2halves(a_in(63 downto 32))), 33);
            else
                v.asum0 := resize(signed(add4bytes(a_in(31 downto 0), e_in.is_signed)), 33);
                v.asum1 := resize(signed(add4bytes(a_in(63 downto 32), e_in.is_signed)), 33);
            end if;

            -- Put B in v.bsum0/1 except for 2nd dword of vsumsws, for
            -- which we put B + vst.asum0 in bsum0.
            if e_in.is_signed = '1' then
                bext0 := resize(signed(b_in(31 downto 0)), 34);
                bext1 := resize(signed(b_in(63 downto 32)), 34);
            else
                bext0 := signed(resize(unsigned(b_in(31 downto 0)), 34));
                bext1 := signed(resize(unsigned(b_in(63 downto 32)), 34));
            end if;
            if sum_across = '1' then
                v.bsum0 := bext0 + resize(vst.asum0, 34);
            else
                v.bsum0 := bext0;
            end if;
            v.bsum1 := bext1;
        end if;

        -- In the following cycle do vst.asum + vst.bsum and saturate
        sum_result := (others => '0');
        if vst.sum_across = '0' or vst.part2 = '1' then
            total := saturate32(resize(vst.asum0, 35) + resize(vst.bsum0, 35),
                                vst.is_signed);
            if total(32) = '1' and vst.do_vsum = '1' then
                v.sat := '1';
            end if;
            sum_result(31 downto 0) := total(31 downto 0);
        end if;
        if vst.data_len(2) = '0' then
            total := saturate32(resize(vst.asum1, 35) + resize(vst.bsum1, 35),
                                vst.is_signed);
            if total(32) = '1' and vst.do_vsum = '1' then
                v.sat := '1';
            end if;
            sum_result(63 downto 32) := total(31 downto 0);
        end if;
        vsum_result <= sum_result;

        -- Stash away result for ops which compute their result in the first cycle
        if e_in.valid = '1' then
            case e_in.sub_select is
                when "000" =>
                    v.result := lvs_result;
                when "001" =>
                    v.result := log_result;
                when "010" =>
                    v.result := move_result;
                when "011" =>
                    v.result := gather_res;
                when others =>
                    v.result := vsel_result;
            end case;
        end if;

        -- execute mtvscr
        if e_in.valid = '1' and e_in.insn_type = OP_MTVSCR and e_in.second = '1' then
            v.ni := b_in(16);
            v.sat := b_in(0);
        end if;

        v.vbpermq := vbperm_byte;

        -- Set up outputs to writeback
        v.w.valid := (vst.part1 and e_in.valid) or vst.part2;
        v.e.done := v.w.valid;
        v.w.instr_tag := vst.itag;
        v.w.write_enable := v.w.valid and vst.writes;
        v.w.write_reg := vst.wr_reg;
        v.w.write_data := vec_result;

        -- write back CR6 result on the second half
        v.w.write_cr_enable := vst.part2 and vst.wr_cr;
        v.w.write_cr_mask := num_to_fxm(6);
        v.w.write_cr_data := x"000000" & vec_cr6 & x"0";

        -- Update SAT
        if v.w.valid = '1' and arith_ovf /= x"00" then
            v.sat := '1';
        end if;

        w_out <= vst.w;
        e_out <= vst.e;

        -- update state
        vst_in <= v;
    end process;
end architecture behaviour;
