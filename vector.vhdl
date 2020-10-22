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
        ni           : std_ulogic;      -- non-IEEE mode
        sat          : std_ulogic;      -- saturation flag
        a0           : std_ulogic_vector(63 downto 0);
        b0           : std_ulogic_vector(63 downto 0);
        perm_sel     : std_ulogic_vector(63 downto 0);
        all0         : std_ulogic;
        all1         : std_ulogic;
        vbpermq      : std_ulogic_vector(7 downto 0);
        vbp_sel      : std_ulogic_vector(31 downto 0);
        carry        : std_ulogic;
        oshift       : unsigned(3 downto 0);
        vs_ext_l     : std_ulogic_vector(7 downto 0);
        vs_ext_r     : std_ulogic_vector(7 downto 0);
        isum         : std_ulogic_vector(33 downto 0);
        vip          : std_ulogic;
        writes       : std_ulogic;
        e            : VectorToExecute1Type;
        w            : VectorToWritebackType;
        varith_res   : std_ulogic_vector(63 downto 0);
        lvs_result   : std_ulogic_vector(63 downto 0);
        log_result   : std_ulogic_vector(63 downto 0);
        move_result  : std_ulogic_vector(63 downto 0);
        gather_res   : std_ulogic_vector(63 downto 0);
        sum_result   : std_ulogic_vector(63 downto 0);
        vperm_result : std_ulogic_vector(63 downto 0);
        overflow     : std_ulogic_vector(7 downto 0);
        sat_msb      : std_ulogic_vector(7 downto 0);
        sat_lsb      : std_ulogic_vector(7 downto 0);
        sub_select   : std_ulogic_vector(2 downto 0);
        set_sat      : std_ulogic;
    end record;
    constant vec_state_init : vec_state := (ni => '0', sat => '0', all0 => '0', all1 => '0',
                                            vbpermq => (others => '0'), vbp_sel => (others => '0'),
                                            oshift => "0000", carry => '0',
                                            vs_ext_l => x"00", vs_ext_r => x"00",
                                            isum => (others => '0'), vip => '0', writes => '0',
                                            e => VectorToExecute1Init, w => VectorToWritebackInit,
                                            set_sat => '0',
                                            others => (others => '0'));

    signal vst, vst_in : vec_state;

    type byte_comparison_t is array(0 to 7) of boolean;

    signal a_in         : std_ulogic_vector(63 downto 0);
    signal b_in         : std_ulogic_vector(63 downto 0);
    signal c_in         : std_ulogic_vector(63 downto 0);
    signal vec_valid    : std_ulogic;
    signal sub_select   : std_ulogic_vector(2 downto 0);
    signal lenm1        : std_ulogic_vector(2 downto 0);
    signal log_len      : std_ulogic_vector(1 downto 0);
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
    signal vperm_result : std_ulogic_vector(63 downto 0);
    signal lvs_result   : std_ulogic_vector(63 downto 0);
    signal varith_res   : std_ulogic_vector(63 downto 0);
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
    signal arith_ovf    : std_ulogic_vector(7 downto 0);
    signal arith_satm   : std_ulogic_vector(7 downto 0);
    signal arith_satl   : std_ulogic_vector(7 downto 0);
    signal satb0        : std_ulogic_vector(7 downto 0);
    signal satb7        : std_ulogic_vector(7 downto 0);
    signal perm_data    : std_ulogic_vector(255 downto 0);
    signal mtvsr_a      : std_ulogic_vector(63 downto 0);
    signal mfvsr_c      : std_ulogic_vector(63 downto 0);
    signal move_sel     : std_ulogic_vector(1 downto 0);
    signal vscr_enable  : std_ulogic;
    signal overflow     : std_ulogic_vector(7 downto 0);
    signal sat_msb      : std_ulogic_vector(7 downto 0);
    signal sat_lsb      : std_ulogic_vector(7 downto 0);
    signal vec_result   : std_ulogic_vector(63 downto 0);
    signal vec_result_ps: std_ulogic_vector(63 downto 0);
    signal sum_overflow : std_ulogic_vector(7 downto 0);
    signal sum_satm     : std_ulogic_vector(7 downto 0);
    signal sum_satl     : std_ulogic_vector(7 downto 0);
    signal cmp_bits     : std_ulogic_vector(7 downto 0);
    signal elt_sign_a   : std_ulogic_vector(7 downto 0);
    signal shift_lsel   : std_ulogic_vector(15 downto 0);
    signal shift_rsel   : std_ulogic_vector(23 downto 0);
    signal shift_sel    : std_ulogic_vector(15 downto 0);
    signal shift_count  : std_ulogic_vector(23 downto 0);
    signal shift_bits   : std_ulogic_vector(47 downto 0);
    signal shift_in     : std_ulogic_vector(127 downto 0);
    signal shift_axl    : std_ulogic_vector(71 downto 0);
    signal shift_axr    : std_ulogic_vector(63 downto 0);
    signal shift_xr     : std_ulogic_vector(7 downto 0);
    signal shift_out    : std_ulogic_vector(63 downto 0);
    signal a_sh         : std_ulogic_vector(63 downto 0);
    signal is_rotate    : std_ulogic;
    signal is_right_sh  : std_ulogic;
    signal shift_whole  : std_ulogic;
    signal leftmost     : std_ulogic_vector(7 downto 0);
    signal rightmost    : std_ulogic_vector(7 downto 0);
    signal vec_cr6      : std_ulogic_vector(3 downto 0);
    signal sat          : std_ulogic;

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

    -- Return the bit index of the byte to the right of byte i,
    -- in cyclic order in elements of eltsize bytes.
    function goright(i: integer; eltsize: integer) return integer is
    begin
        if i mod eltsize = 0 then
            return (i + eltsize - 1) * 8;
        else
            return (i - 1) * 8;
        end if;
    end;

    -- Return the bit index of the LSB of the element containing
    -- byte i, in elements of eltsize bytes
    function elt_right(i: integer; eltsize: integer) return integer is
    begin
        return (i - (i mod eltsize)) * 8;
    end;

    -- Return the upper 8 bits of val << n
    function lshift(val: std_ulogic_vector(15 downto 0); n: integer) return std_ulogic_vector is
    begin
        return val(15 - n downto 8 - n);
    end;

begin

    -- Data path
    a_in <= e_in.vra;
    b_in <= e_in.vrb;
    c_in <= e_in.vrc;
    vec_valid <= e_in.valid;
    sub_select <= e_in.e.sub_select;
    lenm1 <= e_in.e.lenm1;
    log_len <= e_in.e.log_len;

    -- do comparisons for vcmp*, vmin* and vmax*
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

    elt_sign_bits: for i in 0 to 7 generate
        with log_len select elt_sign_a(i) <=
            a_in(i * 8 + 7) and e_in.e.is_signed when "00",
            a_in((i - (i mod 2) + 1) * 8 + 7) and e_in.e.is_signed when "01",
            a_in((i - (i mod 4) + 3) * 8 + 7) and e_in.e.is_signed when "10",
            a_in(63) and e_in.e.is_signed when others;
    end generate;

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
    gather_res <= vgbbd_result when e_in.e.insn(6) = '0'
                  else 64x"0" when vst.vip = '1'
                  else 48x"0" & vbperm_byte & vst.vbpermq;

    -- vector shifts
    -- shift_whole is 1 for vsl, vsr, vslv and vsrv
    shift_whole <= e_in.e.vec_shift_whole;
    is_rotate <= e_in.e.vec_rotate;
    is_right_sh <= e_in.e.vec_shift_right;

    shift_axl <= vst.vs_ext_r & a_in;
    shift_xr <= vst.vs_ext_l when is_rotate = '0' else a_in(63 downto 56);
    shift_axr <= a_in(55 downto 0) & shift_xr;

    -- Note that vsl and vsr are done as per-byte shifts (like vslv
    -- and vsrv) because P9's behaviour is to shift each byte of VRA
    -- by the shift count in the corresponding byte of VRB.  The arch
    -- requires all bytes of VRB to have the same value in the bottom
    -- 3 bits for vsl and vsr.
    vec_shift: for i in 0 to 7 generate
        with log_len select shift_bits(i*6 + 5 downto i*6) <=
            "000" & b_in(i*8 + 2 downto i*8) when "00",
            "00" & b_in(elt_right(i, 2) + 3 downto elt_right(i, 2)) when "01",
            '0' & b_in(elt_right(i, 4) + 4 downto elt_right(i, 4)) when "10",
            b_in(5 downto 0) when others;
        -- negate shift count for right shifts
        shift_count(i*3 + 2 downto i*3) <= shift_bits(i*6 + 2 downto i*6) when is_right_sh = '0'
                                           else std_ulogic_vector(- signed(shift_bits(i*6 + 2 downto i*6)));
        leftmost(i) <= '1' when (std_ulogic_vector(to_unsigned(i + 1, 3)) and lenm1) = "000" else '0';
        rightmost(i) <= '1' when (std_ulogic_vector(to_unsigned(i, 3)) and lenm1) = "000" else '0';

        -- when shifting right, 11 for the leftmost byte of each element,
        -- except when doing vsr/vsrv, when it's 11 for byte 7 of 1st dword.
        shift_lsel(i*2 + 1) <= is_right_sh;
        shift_lsel(i*2) <= leftmost(i) when shift_whole = '0'
                           else '1' when (i = 7 and e_in.e.second = '0')
                           else '0';
        with shift_lsel(i*2 + 1 downto i*2) select shift_in(i*16 + 15 downto i*16 + 8) <=
            shift_axl(i*8 + 15 downto i*8 + 8) when "10",
            (others => elt_sign_a(i)) when "11",
            shift_axl(i*8 + 7 downto i*8) when others;

        -- when shifting left (not rotating), 1 for the rightmost byte of each element;
        -- when doing vsl/vslv, 1 for byte 0 of the 1st dword
        shift_rsel(i*3 + 2) <= '0' when is_right_sh = '1'
                               else rightmost(i) when (is_rotate = '0' and shift_whole = '0')
                               else '1' when (shift_whole = '1' and i = 0 and e_in.e.second = '0')
                               else '0';
        shift_rsel(i*3 + 1 downto i*3) <= "00" when is_right_sh = '1'
                                          else log_len when shift_whole = '0'
                                          else "11";
        with shift_rsel(i*3 + 2 downto i*3) select shift_in(i*16 + 7 downto i*16) <=
            a_in(i*8 + 7 downto i*8) when "000",
            a_in(goright(i, 2) + 7 downto goright(i, 2)) when "001",
            a_in(goright(i, 4) + 7 downto goright(i, 4)) when "010",
            shift_axr(i*8 + 7 downto i*8) when "011",
            x"00" when others;

        shift_out(i*8 + 7 downto i*8) <= lshift(shift_in(i*16 + 15 downto i*16),
                                                to_integer(unsigned(shift_count(i*3 + 2 downto i*3))));

        with shift_sel(i*2 + 1 downto i*2) select a_sh(i*8 + 7 downto i*8) <= 
            shift_out(i*8 + 7 downto i*8) when "10",
            (others => elt_sign_a(i)) when "11",
            a_in(i*8 + 7 downto i*8) when others;
    end generate;

    -- vcmp* result, done via saturation logic
    with e_in.e.insn(9 downto 6) & e_in.e.insn(0) select cmp_bits <=
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

    -- mfvscr/mfvsr*/mtvsr*
    mtvsr_a(31 downto 0) <= a_in(31 downto 0);
    mtvsr_a(63 downto 32) <= a_in(63 downto 32) when e_in.e.is_32bit = '0'
                             else a_in(31 downto 0) when e_in.e.insn(9) = '1'
                             else (63 downto 32 => (a_in(31) and e_in.e.sign_extend));
    mfvsr_c(31 downto 0) <= c_in(31 downto 0);
    mfvsr_c(63 downto 32) <= c_in(63 downto 32) when e_in.e.is_32bit = '0'
                             else (others => '0');
    move_sel <= "00" when e_in.e.insn(26) = '0'
                else "01" when e_in.e.insn(8) = '0'
                else "10" when e_in.e.second = '0'
                else "00" when e_in.e.insn(9) = '0'
                else "11" when e_in.e.insn(6) = '1'
                else "10";
    vscr_enable <= (not e_in.e.insn(26)) and e_in.e.second;
    sat <= vst.sat or (vst.set_sat and (or (vst.overflow)));
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
    is_subtract <= e_in.e.insn(10);
    -- vadduqm, vsubuqm use vst.carry; note these are done LS then MS
    cin <= vst.carry when e_in.e.second = '1' and e_in.e.insn(9 downto 6) = "0100"
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
    -- We abuse the e_in.e.sign_extend flag as a indication of which
    -- instructions do saturation.
    ovf_detect: for i in 0 to 7 generate
        -- unsigned overflow: carry=1 for add, carry=0 for sub
        uovf_hi(i) <= not is_subtract and vsum(i * 9 + 8) and not e_in.e.is_signed;
        uovf_lo(i) <= is_subtract and not vsum(i * 9 + 8) and not e_in.e.is_signed;
        -- signed overflow: if result sign /= both operand signs
        sovf_hi(i) <= not vop_a(i * 9 + 7) and not vop_b(i * 9 + 7) and vsum(i * 9 + 7) and e_in.e.is_signed;
        sovf_lo(i) <= vop_a(i * 9 + 7) and vop_b(i * 9 + 7) and not vsum(i * 9 + 7) and e_in.e.is_signed;
    end generate;
    byte_ovf <= uovf_hi or uovf_lo or sovf_hi or sovf_lo;
    satb0 <= sovf_hi or uovf_hi;
    satb7 <= sovf_lo or uovf_hi;
    arith_ovf <= spreadbits(log_len, byte_ovf, byte_ovf) and (7 downto 0 => e_in.e.sign_extend);
    arith_satm <= spreadbits(log_len, satb7, satb0);
    arith_satl <= spreadbits(log_len, satb0, satb0);
    -- generate the output
    sum_output: for i in 0 to 7 generate
        varith_res(i * 8 + 7 downto i * 8) <= vsum(i * 9 + 7 downto i * 9);
    end generate;

    -- Final result mux and saturation logic
    with vst.sub_select select vec_result_ps <=
        vst.varith_res   when "000",
        vst.lvs_result   when "001",
        vst.log_result   when "011",
        vst.move_result  when "100",
        vst.gather_res   when "101",
        vst.sum_result   when "110",
        vst.vperm_result when "111",
        64x"0"       when others;
    with sub_select select overflow <=
        arith_ovf    when "000",
        cmp_bits     when "010",
        sum_overflow when "110",
        x"00"        when others;
    with sub_select select sat_msb <=
        arith_satm when "000",
        x"ff"      when "010",
        sum_satm   when "110",
        x"00"      when others;
    with sub_select select sat_lsb <=
        arith_satl when "000",
        x"ff"      when "010",
        sum_satl   when "110",
        x"00"      when others;
    sat_output: for i in 0 to 7 generate
        vec_result(i*8 + 7 downto i*8) <= vec_result_ps(i*8 + 7 downto i*8) when vst.overflow(i) = '0' else
                                          vst.sat_msb(i) & (6 downto 0 => vst.sat_lsb(i));
    end generate;

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
        variable b_sh         : std_ulogic_vector(63 downto 0);
        variable store_ab     : std_ulogic;
        variable all0, all1   : std_ulogic;
        variable byte         : std_ulogic_vector(7 downto 0);
        variable oshift       : unsigned(3 downto 0);
        variable index        : std_ulogic_vector(4 downto 0);
        variable shift        : std_ulogic_vector(5 downto 0);
        variable shift_col    : std_ulogic_vector(2 downto 0);
        variable src_byte     : std_ulogic_vector(2 downto 0);
        variable byte_in_elt  : std_ulogic_vector(2 downto 0);
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
    begin
        v := vst;
        v.e.busy := '0';
        v.w.valid := '0';
        v.vip := '0';
        v.set_sat := '0';

        if vec_valid = '1' then
            v.w.valid := '1';
            v.w.write_reg := e_in.e.write_reg;
            v.writes := e_in.e.write_reg_enable;
            case e_in.e.insn_type is
            when OP_VPERM | OP_VPACK | OP_VMERGE | OP_XPERM | OP_VBPERM | OP_VMINMAX |
                OP_VSHIFT | OP_VSHOCT =>
                -- These have a busy cycle and take 3 cycles for the 2
                -- iterations of the instruction.
                if e_in.e.second = '0' then
                    v.w.valid := '0';
                    v.e.busy := '1';
                    v.vip := '1';
                end if;

            when others =>
            end case;
        elsif vst.vip = '1' then
            -- wait for the second half to be presented
            if e_in.e.valid = '0' then
                v.vip := '1';
                v.e.busy := '1';
            else
                v.w.valid := '1';
            end if;
        end if;

        b_sh := b_in;
        store_ab := not e_in.e.second;

        shift_sel <= (others => '0');

        -- Compute permutation vector v.perm_sel
        if e_in.e.valid = '1' then
            case e_in.e.insn_type is
            when OP_XPERM =>
                -- OP_XPERM
                if e_in.e.second = '0' then
                    b := e_in.e.insn(9);
                else
                    b := e_in.e.insn(8);
                end if;
                for i in 0 to 7 loop
                    k := i * 8;
                    v.perm_sel(k + 7 downto k) := "000" & not e_in.e.second &
                                                  not b & std_ulogic_vector(to_unsigned(i, 3));
                end loop;
            when OP_VPERM =>
                -- OP_VPERM, columns 2b, 2c, 3b
                if e_in.e.insn(2) = '1' then
                    -- vsldoi
                    m := 16 - to_integer(unsigned(e_in.e.insn(9 downto 6)));
                    if e_in.e.second = '0' then
                        m := m + 8;
                    end if;
                    for i in 0 to 7 loop
                        k := i * 8;
                        v.perm_sel(k + 7 downto k) := "000" & std_ulogic_vector(to_unsigned(m, 5) + to_unsigned(i, 5));
                    end loop;
                elsif e_in.e.insn(4) = '0' then
                    -- vperm
                    v.perm_sel := not c_in;
                else
                    -- vpermr
                    v.perm_sel := c_in;
                end if;
            when OP_VMINMAX =>
                -- OP_VMINMAX, column 02
                -- e_in.e.insn(9) is 1 for vmin, 0 for vmax
                case e_in.e.insn(8 downto 6) is
                    when "100" =>
                        -- vmaxsb, vminsb
                        for i in 0 to 7 loop
                            k := i * 8;
                            v.perm_sel(k + 7 downto k) := "000" & (cmpgt(i) xor e_in.e.insn(9)) &
                                                          not e_in.e.second & std_ulogic_vector(to_unsigned(i, 3));
                        end loop;
                    when "000" =>
                        -- vmaxub, vminub
                        for i in 0 to 7 loop
                            k := i * 8;
                            v.perm_sel(k + 7 downto k) := "000" & (cmpgtu(i) xor e_in.e.insn(9)) &
                                                          not e_in.e.second & std_ulogic_vector(to_unsigned(i, 3));
                        end loop;
                    when "101" =>
                        -- vmaxsh, vminsh
                        for i in 0 to 3 loop
                            k := i * 16;
                            v.perm_sel(k + 7 downto k) := "000" & (hcmpgt(i) xor e_in.e.insn(9)) &
                                                          not e_in.e.second & std_ulogic_vector(to_unsigned(i, 2)) & '0';
                            v.perm_sel(k + 15 downto k + 8) := "000" & (hcmpgt(i) xor e_in.e.insn(9)) &
                                                               not e_in.e.second & std_ulogic_vector(to_unsigned(i, 2)) & '1';
                        end loop;
                    when "001" =>
                        -- vmaxuh, vminuh
                        for i in 0 to 3 loop
                            k := i * 16;
                            v.perm_sel(k + 7 downto k) := "000" & (hcmpgtu(i) xor e_in.e.insn(9)) &
                                                          not e_in.e.second & std_ulogic_vector(to_unsigned(i, 2)) & '0';
                            v.perm_sel(k + 15 downto k + 8) := "000" & (hcmpgtu(i) xor e_in.e.insn(9)) &
                                                               not e_in.e.second & std_ulogic_vector(to_unsigned(i, 2)) & '1';
                        end loop;
                    when "110" =>
                        -- vmaxsw, vminsw
                        for i in 0 to 1 loop
                            for m in i * 4 to i * 4 + 3 loop
                                k := m * 8;
                                v.perm_sel(k + 7 downto k) := "000" & (wcmpgt(i) xor e_in.e.insn(9)) &
                                                              not e_in.e.second &
                                                              std_ulogic_vector(to_unsigned(m, 3));
                            end loop;
                        end loop;
                    when "010" =>
                        -- vmaxuw, vminuw
                        for i in 0 to 1 loop
                            for m in i * 4 to i * 4 + 3 loop
                                k := m * 8;
                                v.perm_sel(k + 7 downto k) := "000" & (wcmpgtu(i) xor e_in.e.insn(9)) &
                                                              not e_in.e.second &
                                                              std_ulogic_vector(to_unsigned(m, 3));
                            end loop;
                        end loop;
                    when "111" =>
                        -- vmaxsd, vminsd
                        for m in 0 to 7 loop
                            k := m * 8;
                            v.perm_sel(k + 7 downto k) := "000" & (dcmpgt xor e_in.e.insn(9)) &
                                                          not e_in.e.second &
                                                          std_ulogic_vector(to_unsigned(m, 3));
                        end loop;
                    when others =>
                        -- vmaxud, vminud
                        for m in 0 to 7 loop
                            k := m * 8;
                            v.perm_sel(k + 7 downto k) := "000" & (dcmpgtu xor e_in.e.insn(9)) &
                                                          not e_in.e.second &
                                                          std_ulogic_vector(to_unsigned(m, 3));
                        end loop;
                end case;
            when OP_VPACK =>
                -- OP_VPACK, column 0e
                if e_in.e.insn(6) = '0' then
                    -- vpkuhum
                    for i in 0 to 7 loop
                        k := i * 8;
                        m := i * 2;
                        if e_in.e.second = '0' then
                            m := m + 16;
                        end if;
                        v.perm_sel(k + 7 downto k) := std_ulogic_vector(to_unsigned(m, 8));
                    end loop;
                elsif e_in.e.insn(10) = '0' then
                    -- vpkuwum
                    for i in 0 to 3 loop
                        k := i * 16;
                        m := i * 4;
                        if e_in.e.second = '0' then
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
                        if e_in.e.second = '0' then
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
                case e_in.e.insn(10 downto 6) is
                    when "01000" =>
                        -- vspltb
                        for i in 0 to 7 loop
                            k := i * 8;
                            v.perm_sel(k + 7 downto k) := "0000" & not e_in.e.insn(19 downto 16);
                        end loop;
                    when "01001" =>
                        -- vsplth
                        for i in 0 to 3 loop
                            k := i * 16;
                            v.perm_sel(k + 7 downto k) := "0000" & not e_in.e.insn(18 downto 16) & '0';
                            v.perm_sel(k + 15 downto k + 8) := "0000" & not e_in.e.insn(18 downto 16) & '1';
                        end loop;
                    when "01010" =>
                        -- vspltw
                        for i in 0 to 1 loop
                            k := i * 32;
                            v.perm_sel(k + 7 downto k) := "0000" & not e_in.e.insn(17 downto 16) & "00";
                            v.perm_sel(k + 15 downto k + 8) := "0000" & not e_in.e.insn(17 downto 16) & "01";
                            v.perm_sel(k + 23 downto k + 16) := "0000" & not e_in.e.insn(17 downto 16) & "10";
                            v.perm_sel(k + 31 downto k + 24) := "0000" & not e_in.e.insn(17 downto 16) & "11";
                        end loop;
                    when "01100" =>
                        -- vspltisb
                        b_sh := std_ulogic_vector(resize(signed(e_in.e.insn(20 downto 16)), 64));
                        v.perm_sel := x"0808080808080808";
                    when "01101" =>
                        -- vspltish
                        b_sh := std_ulogic_vector(resize(signed(e_in.e.insn(20 downto 16)), 64));
                        v.perm_sel := x"0908090809080908";
                    when "01110" =>
                        -- vspltisw
                        b_sh := std_ulogic_vector(resize(signed(e_in.e.insn(20 downto 16)), 64));
                        v.perm_sel := x"0b0a09080b0a0908";
                    when "00000" =>
                        -- vmrghb
                        if e_in.e.second = '0' then
                            v.perm_sel := x"1f0f1e0e1d0d1c0c";
                        else
                            v.perm_sel := x"1b0b1a0a19091808";
                        end if;
                    when "00100" =>
                        -- vmrglb
                        if e_in.e.second = '0' then
                            v.perm_sel := x"1707160615051404";
                        else
                            v.perm_sel := x"1303120211011000";
                        end if;
                    when "00001" =>
                        -- vmrghh
                        if e_in.e.second = '0' then
                            v.perm_sel := x"1f1e0f0e1d1c0d0c";
                        else
                            v.perm_sel := x"1b1a0b0a19180908";
                        end if;
                    when "00101" =>
                        -- vmrglh
                        if e_in.e.second = '0' then
                            v.perm_sel := x"1716070615140504";
                        else
                            v.perm_sel := x"1312030211100100";
                        end if;
                    when "00010" =>
                        -- vmrghw
                        if e_in.e.second = '0' then
                            v.perm_sel := x"1f1e1d1c0f0e0d0c";
                        else
                            v.perm_sel := x"1b1a19180b0a0908";
                        end if;
                    when "00110" =>
                        -- vmrglw
                        if e_in.e.second = '0' then
                            v.perm_sel := x"1716151407060504";
                        else
                            v.perm_sel := x"1312111003020100";
                        end if;
                    when "11110" =>
                        -- vmrgew
                        if e_in.e.second = '0' then
                            v.perm_sel := x"1f1e1d1c0f0e0d0c";
                        else
                            v.perm_sel := x"1716151407060504";
                        end if;
                    when "11010" =>
                        -- vmrgow
                        if e_in.e.second = '0' then
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
                if e_in.e.insn(6) = '0' then
                    -- vslo
                    -- we do LS then MS because the shift count is in the
                    -- LS half of VRB
                    if e_in.e.second = '0' then
                        oshift := unsigned(b_in(6 downto 3));
                        v.oshift := oshift;
                    else
                        oshift := vst.oshift;
                    end if;
                    for i in 0 to 7 loop
                        k := i * 8;
                        index := '1' & e_in.e.second & std_ulogic_vector(to_unsigned(i, 3));
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
                    if e_in.e.second = '0' then
                        oshift := unsigned(b_in(6 downto 3));
                        v.oshift := oshift;
                    else
                        oshift := vst.oshift;
                    end if;
                    for i in 0 to 7 loop
                        k := i * 8;
                        index := '0' & e_in.e.second & std_ulogic_vector(to_unsigned(i, 3));
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
                for i in 0 to 7 loop
                    k := i * 8;
                    -- Calculate permutation vector for rotating the bytes of
                    -- this element
                    shift_col := std_ulogic_vector(to_unsigned(i, 3)) and not lenm1;
                    shift := shift_bits(i * 6 + 5 downto i * 6);
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
                    if is_empty = '1' then
                        shift_sel(i*2 + 1 downto i*2) <= "11";
                    elsif shift(2 downto 0) /= "000" then
                        shift_sel(i*2 + 1 downto i*2) <= "10";
                    end if;
                end loop;
            when others =>
                v.perm_sel := (others => '0');
            end case;
        end if;

        if e_in.e.valid = '1' then
            v.vs_ext_r := a_in(7 downto 0);
            v.vs_ext_l := a_in(63 downto 56);
        end if;
        if e_in.e.valid = '1' and store_ab = '1' then
            v.a0 := a_sh;
            v.b0 := b_sh;
        end if;

        if e_in.e.second = '0' then
            all0 := '1';
            all1 := '1';
        else
            all0 := vst.all0;
            all1 := vst.all1;
        end if;
        all0 := all0 and not (or (cmp_bits));
        all1 := all1 and (and (cmp_bits));
        vec_cr6 <= all1 & '0' & all0 & '0';
        if vec_valid = '1' then
            v.all0 := all0;
            v.all1 := all1;
        end if;

        -- compute result for lvsl or lvsr
        sum := (others => '0');
        sum(3 downto 0) := unsigned(a_in(3 downto 0)) + unsigned(b_in(3 downto 0));
        if e_in.e.insn(6) = '1' then
            -- lvsr
            sum := to_unsigned(16, 8) - sum;
        end if;
        if e_in.e.second = '1' then
            sum := sum + to_unsigned(8, 8);
        end if;
        for i in 0 to 7 loop
            k := i * 8;
            lvs_result(k + 7 downto k) <= std_ulogic_vector(sum + to_unsigned(7 - i, 8));
        end loop;

        -- compute vector logical result
        if e_in.e.insn(5) = '1' then
            -- vsel
            log_result <= (a_in and not c_in) or (b_in and c_in);
        else
            case e_in.e.insn(8 downto 6) is
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

        if e_in.e.valid = '1' then
            v.vbpermq := vbperm_byte;
        end if;

        -- execute mtvscr
        if vec_valid = '1' and e_in.e.insn_type = OP_MTVSCR and e_in.e.second = '1' then
            v.ni := b_in(16);
            v.sat := b_in(0);
        else
            v.sat := sat;
        end if;

        -- vector arithmetic
        v.carry := vsum(71);

        -- Sum-across logic
        word0 := a_in(31) & a_in(31) & a_in(31 downto 0);
        word1 := a_in(63) & a_in(63) & a_in(63 downto 32);
        word_sum := std_ulogic_vector(unsigned(word0) + unsigned(word1));
        if vec_valid = '1' then
            if e_in.e.second = '0' and e_in.e.insn_type = OP_VSUM and e_in.e.insn(8 downto 6) = "110" then
                v.isum := word_sum;
            else
                v.isum := (others => '0');
            end if;
        end if;

        word2 := std_ulogic_vector(unsigned(b_in(31) & b_in(31) & b_in(31 downto 0)) +
                                   unsigned(vst.isum));

        if e_in.e.data_len(2) = '1' then
            -- vsumsws, vsum2sws
            sum_result(63 downto 32) <= x"00000000";
            sum_overflow(7 downto 4) <= "0000";
            sum_satm(7 downto 4) <= "0000";
            sum_satl(7 downto 4) <= "0000";
            if e_in.e.second = '1' or e_in.e.insn(8) = '0' then
                total := std_ulogic_vector(unsigned(word2(33) & word2) +
                                           unsigned(word_sum(33) & word_sum));
                sum_result(31 downto 0) <= total(31 downto 0);
                -- work out whether to saturate
                if total(34 downto 31) = "0000" or total(34 downto 31) = "1111" then
                    sum_overflow(3 downto 0) <= "0000";
                else
                    sum_overflow(3 downto 0) <= "1111";
                end if;
                if total(34) = '0' then
                    -- saturate to 0x7fffffff
                    sum_satm(3 downto 0) <= "0111";
                    sum_satl(3 downto 0) <= "1111";
                else
                    -- saturate to 0x80000000
                    sum_satm(3 downto 0) <= "1000";
                    sum_satl(3 downto 0) <= "0000";
                end if;
            else
                sum_result(31 downto 0) <= x"00000000";
                sum_overflow(3 downto 0) <= "0000";
                sum_satm(3 downto 0) <= "0000";
                sum_satl(3 downto 0) <= "0000";
            end if;

        else
            -- vsum4sbs, vsum4ubs, vsum4shs
            for i in 0 to 1 loop
                -- sum across groups of 4 bytes (signed or unsigned)
                k := i * 32;
                byte0 := (e_in.e.is_signed and a_in(k + 7)) & a_in(k + 7 downto k);
                byte1 := (e_in.e.is_signed and a_in(k + 15)) & a_in(k + 15 downto k + 8);
                bsum0 := std_ulogic_vector(unsigned(byte0) + unsigned(byte1));
                byte2 := (e_in.e.is_signed and a_in(k + 23)) & a_in(k + 23 downto k + 16);
                byte3 := (e_in.e.is_signed and a_in(k + 31)) & a_in(k + 31 downto k + 24);
                bsum1 := std_ulogic_vector(unsigned(byte2) + unsigned(byte3));
                byte_sum := std_ulogic_vector(unsigned((e_in.e.is_signed and bsum0(8)) & bsum0) +
                                              unsigned((e_in.e.is_signed and bsum1(8)) & bsum1));

                -- sum across half-words, always signed
                half0 := a_in(k + 15) & a_in(k + 15 downto k);
                half1 := a_in(k + 31) & a_in(k + 31 downto k + 16);
                half_sum := std_ulogic_vector(unsigned(half0) + unsigned(half1));

                if e_in.e.data_len(0) = '1' then
                    signbit := e_in.e.is_signed and byte_sum(9);
                    sum1(32 downto 10) := (others => signbit);
                    sum1(9 downto 0) := byte_sum;
                else
                    sum1 := std_ulogic_vector(resize(signed(half_sum), 33));
                end if;

                signbit := e_in.e.is_signed and b_in(k + 31);
                sum2 := std_ulogic_vector(unsigned(signbit & b_in(k + 31 downto k)) +
                                          unsigned(sum1));
                
                sum_result(k + 31 downto k) <= sum2(31 downto 0);
                if (e_in.e.is_signed and sum2(31)) = sum2(32) then
                    sum_overflow(i*4 + 3 downto i*4) <= "0000";
                else
                    sum_overflow(i*4 + 3 downto i*4) <= "1111";
                end if;
                if e_in.e.is_signed = '0' then
                    -- saturate to 0xffffffff
                    sum_satm(i*4 + 3 downto i*4) <= "1111";
                    sum_satl(i*4 + 3 downto i*4) <= "1111";
                elsif sum2(32) = '0' then
                    -- saturate to 0x7fffffff
                    sum_satm(i*4 + 3 downto i*4) <= "0111";
                    sum_satl(i*4 + 3 downto i*4) <= "1111";
                else
                    -- saturate to 0x80000000
                    sum_satm(i*4 + 3 downto i*4) <= "1000";
                    sum_satl(i*4 + 3 downto i*4) <= "0000";
                end if;
            end loop;
        end if;
        if (e_in.e.insn_type = OP_VSUM or e_in.e.insn_type = OP_VARITH) and vec_valid = '1' then
            v.set_sat := '1';
        end if;

        v.varith_res := varith_res;
        v.lvs_result := lvs_result;
        v.log_result := log_result;
        v.move_result := move_result;
        v.gather_res := gather_res;
        v.sum_result := sum_result;
        v.vperm_result := vperm_result;
        v.overflow := overflow;
        v.sat_msb := sat_msb;
        v.sat_lsb := sat_lsb;
        v.sub_select := sub_select;

        v.w.write_enable := v.w.valid and v.writes;

        -- write back CR6 result on the second half
        v.w.write_cr_enable := vec_valid and e_in.e.output_cr and e_in.e.second;
        v.w.write_cr_data := x"000000" & vec_cr6 & x"0";

        w_out.valid <= vst.w.valid;
        w_out.write_enable <= vst.w.write_enable;
        w_out.write_reg <= vst.w.write_reg;
        w_out.write_data <= vec_result;
        w_out.write_cr_enable <= vst.w.write_cr_enable;
        w_out.write_cr_mask <= num_to_fxm(6);
        w_out.write_cr_data <= vst.w.write_cr_data;

        e_out <= vst.e;

        -- update state
        vst_in <= v;
    end process;
end architecture behaviour;
