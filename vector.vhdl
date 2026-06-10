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
        flush_in        : in  std_ulogic;
        e_in            : in  Execute1ToVectorType;
        e_out           : out VectorToExecute1Type;
        w_out           : out VectorToWritebackType
        );
end entity vector_unit;

architecture behaviour of vector_unit is

    -- State for vector instructions
    type vec_stage1_type is record
        e        : VectorToWritebackType;
        busy     : std_ulogic;
        rsel     : vec_result_sel_t;
        bits     : std_ulogic_vector(255 downto 0);
        sel      : std_ulogic_vector(127 downto 0);
        shcnt    : std_ulogic_vector(63 downto 0);

        perm_counter : unsigned(1 downto 0);
        wdat_valid : std_ulogic;
        do_vperm : std_ulogic;
        is_vbpermq : std_ulogic;
        do_mult_32 : std_ulogic;
        is_mtvscr  : std_ulogic;

        is_shift       : std_ulogic;
        is_rotate      : std_ulogic;
        is_right_shift : std_ulogic;
        lg_length      : std_ulogic_vector(2 downto 0);

        vadd_data  : std_ulogic_vector(127 downto 0);
        vlog_data  : std_ulogic_vector(127 downto 0);
        vmisc_data : std_ulogic_vector(127 downto 0);
        vgbbd_data : std_ulogic_vector(127 downto 0);
    end record;
    constant vec_stage1_init : vec_stage1_type :=
        (e => VectorToWritebackInit,
         rsel => ADD,
         bits => (others => '0'), sel => (others => '0'),
         shcnt => (others => '0'),
         perm_counter => "00",
         lg_length => "000",
         vadd_data => (others => '0'),
         vlog_data => (others => '0'),
         vmisc_data => (others => '0'),
         vgbbd_data => (others => '0'),
         others => '0');

    type vec_stage2_type is record
        e        : VectorToWritebackType;
    end record;
    constant vec_stage2_init : vec_stage2_type :=
        (e => VectorToWritebackInit);

    signal vs1, vs1in : vec_stage1_type;
    signal vs2, vs2in : vec_stage2_type;

    signal a_in : std_ulogic_vector(127 downto 0);
    signal b_in : std_ulogic_vector(127 downto 0);
    signal c_in : std_ulogic_vector(127 downto 0);
    signal vadd_result : std_ulogic_vector(127 downto 0);
    signal vlog_result : std_ulogic_vector(127 downto 0);
    signal vmisc_result : std_ulogic_vector(127 downto 0);
    signal vgbbd_result : std_ulogic_vector(127 downto 0);
    signal lvs_vector : std_ulogic_vector(127 downto 0);
    signal vec_cr6 : std_ulogic_vector(3 downto 0);
    signal vshiftbits : std_ulogic_vector(63 downto 0);
    signal vshiftsel : std_ulogic_vector(63 downto 0);

    signal mult_hi_in, mult_lo_in : MultiplyInputType;
    signal mult_hi_out, mult_lo_out : MultiplyOutputType;

    signal vscr_sat  : std_ulogic;
    signal vscr_nj   : std_ulogic;
    signal do_mtvscr : std_ulogic;

begin

    mult_hi_0: entity work.multiply_32s
        port map (
            clk => clk,
            stall => e_in.stall,
            m_in => mult_hi_in,
            m_out => mult_hi_out
            );

    mult_lo_0: entity work.multiply_32s
        port map (
            clk => clk,
            stall => e_in.stall,
            m_in => mult_lo_in,
            m_out => mult_lo_out
            );

    -- Data path
    a_in <= e_in.vra_hi & e_in.vra_lo;
    b_in <= e_in.vrb_hi & e_in.vrb_lo;
    c_in <= e_in.vrc_hi & e_in.vrc_lo;

    vector_dp: process(all)
        variable mtvsr_result : std_ulogic_vector(63 downto 0);
        variable negative : std_ulogic;
        variable a_inv, b_inv : std_ulogic_vector(127 downto 0);
        variable lvs_result : std_ulogic_vector(127 downto 0);
        variable vcz_result : std_ulogic_vector(127 downto 0);
        variable splti_result : std_ulogic_vector(127 downto 0);
        variable vcmp_eqb : std_ulogic_vector(15 downto 0);
        variable vcmp_res : std_ulogic_vector(15 downto 0);
        variable vcmp_crf : std_ulogic_vector(3 downto 0);
        variable size_mask : unsigned(2 downto 0);
        variable nib : unsigned(3 downto 0);
        variable lvsum : unsigned(4 downto 0);
        variable a_ext_hi, a_ext_lo : unsigned(71 downto 0);
        variable b_ext_hi, b_ext_lo : unsigned(71 downto 0);
        variable sum_ext_hi, sum_ext_lo : unsigned(71 downto 0);
        variable vcz_bits, vcz_onehot : std_ulogic_vector(15 downto 0);
    begin
        vcmp_eqb := (others => '0');
        for i in 0 to 15 loop
            if a_in(i*8 + 7 downto i*8) = b_in(i*8 + 7 downto i*8) then
                vcmp_eqb(i) := '1';
            end if;
        end loop;
        vcmp_res := (others => '0');
        vcmp_crf := "1010";
        for i in 0 to 15 loop
            vcmp_res(i) := vcmp_eqb(i) xor e_in.invert_out;
            if vcmp_res(i) = '0' then
                vcmp_crf(3) := '0';
            else
                vcmp_crf(1) := '0';
            end if;
        end loop;

        -- Segmented adder
        size_mask := unsigned(e_in.length(2 downto 0)) - 1;
        a_ext_hi := (others => '0');
        a_ext_lo := (others => '0');
        b_ext_hi := (others => '0');
        b_ext_lo := (others => '0');
        for i in 0 to 7 loop
            a_ext_hi(i*9 + 7 downto i*9) := unsigned(e_in.vra_hi(i*8 + 7 downto i*8));
            a_ext_lo(i*9 + 7 downto i*9) := unsigned(e_in.vra_lo(i*8 + 7 downto i*8));
            b_ext_hi(i*9 + 7 downto i*9) := unsigned(e_in.vrb_hi(i*8 + 7 downto i*8));
            b_ext_lo(i*9 + 7 downto i*9) := unsigned(e_in.vrb_lo(i*8 + 7 downto i*8));
            -- set extra bits to propagate carries for 2, 4, 8-byte ops
            if i > 0 and std_ulogic_vector((to_unsigned(i, 3) and size_mask)) /= "000" then
                b_ext_hi(i*9 - 1) := '1';
                b_ext_lo(i*9 - 1) := '1';
            end if;
        end loop;
        sum_ext_hi := a_ext_hi + b_ext_hi;
        sum_ext_lo := a_ext_lo + b_ext_lo;
        vadd_result <= (others => '0');
        for i in 0 to 7 loop
            vadd_result(i*8 + 64 + 7 downto i*8 + 64) <= std_ulogic_vector(sum_ext_hi(i*9 + 7 downto i*9));
            vadd_result(i*8 + 7 downto i*8) <= std_ulogic_vector(sum_ext_lo(i*9 + 7 downto i*9));
        end loop;

        -- Logical and permutation operations, also some moves and splats
        vlog_result <= (others => '0');
        vec_cr6 <= (others => '0');
        case e_in.sub_select is
            when "000" =>
                -- mtvsr*
                vlog_result(127 downto 64) <= e_in.vra_hi;
                vlog_result(63 downto 0) <= e_in.vrb_hi;
                if e_in.is_32bit = '1' then
                    -- mtvsr{wa,wz,ws} - select the A input, truncated
                    -- to 32 bits and possibly sign-extended or splatted
                    -- abuse invert_out field of decode table to indicate splat.
                    mtvsr_result := e_in.vra_hi;
                    if e_in.invert_out = '1' then
                        mtvsr_result(63 downto 32) := e_in.vra_hi(31 downto 0);
                        vlog_result(63 downto 0) <= mtvsr_result;
                    else
                        negative := e_in.is_signed and e_in.vra_hi(31);
                        mtvsr_result(63 downto 32) := (others => negative);
                    end if;
                    vlog_result(127 downto 64) <= mtvsr_result;
                end if;
            when "001" =>
                -- mfvsr*; mfvsrld has invert_out = 1, mfvsrwz has is_32bit = 1
                if e_in.invert_out = '1' then
                    vlog_result(127 downto 64) <= e_in.vrc_lo;
                else
                    vlog_result(127 downto 64) <= e_in.vrc_hi;
                end if;
                if e_in.is_32bit = '1' then
                    vlog_result(127 downto 96) <= (others => '0');
                end if;
            when "010" =>
                -- vand[c], vor[c], etc.
                -- use 'is_signed' flag to indicate inversion of B
                a_inv := a_in;
                if e_in.invert_a = '1' then
                    a_inv := not a_in;
                end if;
                b_inv := b_in;
                if e_in.is_signed = '1' then
                    b_inv := not b_in;
                end if;
                if e_in.invert_out = '0' then
                    vlog_result <= a_inv and b_inv;
                else
                    vlog_result <= not (a_inv and b_inv);
                end if;
            when "011" =>
                -- vxor, veqv
                a_inv := a_in;
                if e_in.invert_a = '1' then
                    a_inv := not a_in;
                end if;
                vlog_result <= a_inv xor b_in;
            when "100" =>
                -- xxpermdi
                vlog_result <= e_in.vra_hi & e_in.vrb_hi;
                if e_in.insn(9) = '1' then
                    vlog_result(127 downto 64) <= e_in.vra_lo;
                end if;
                if e_in.insn(8) = '1' then
                    vlog_result(63 downto 0) <= e_in.vrb_lo;
                end if;
            when "101" =>
                -- mfvscr
                vlog_result(0) <= vscr_sat;
                vlog_result(16) <= vscr_nj;
            when "110" =>
                -- vector comparison result
                for i in 0 to 15 loop
                    vlog_result(i*8 + 7 downto i*8) <= (others => vcmp_res(i));
                end loop;
                vec_cr6 <= vcmp_crf;
            when "111" =>
                -- splat-immediate result
                for i in 0 to 15 loop
                    -- we can always use either byte 0 or byte 1, since bytes
                    -- 2 and 3 are the same as byte 1
                    if std_ulogic_vector(to_unsigned(i mod 4, 3) and size_mask) /= "000" then
                        splti_result(i*8 + 7 downto i*8) := e_in.vrb_hi(15 downto 8);
                    else
                        splti_result(i*8 + 7 downto i*8) := e_in.vrb_hi(7 downto 0);
                    end if;
                end loop;
                vlog_result <= splti_result;
            when others =>
        end case;

        -- vgbbd does a bit/byte transpose on each half of the input
        for i in 0 to 7 loop
            for j in 0 to 7 loop
                vgbbd_result(i*8 + j) <= b_in(j*8 + i);
                vgbbd_result(i*8 + j + 64) <= b_in(j*8 + i + 64);
            end loop;
        end loop;

        -- Other miscellaneous operations
        -- The lvsl machinery is also used to generate a permute
        -- vector for vsldoi.
        lvs_result := (others => '0');
        if e_in.sub_select(1) = '0' then
            nib := unsigned(e_in.vra_hi(3 downto 0)) + unsigned(e_in.vrb_hi(3 downto 0));
        else
            nib := unsigned(e_in.insn(9 downto 6));
        end if;
        if e_in.invert_out = '0' then
            -- lvsl
            for i in 0 to 15 loop
                lvsum := to_unsigned(15 - i, 5) + resize(nib, 5);
                lvs_result(i*8 + 4 downto i*8) := std_ulogic_vector(lvsum);
            end loop;
        else
            -- lvsr
            for i in 0 to 15 loop
                lvsum := to_unsigned(31 - i, 5) - resize(nib, 5);
                lvs_result(i*8 + 4 downto i*8) := std_ulogic_vector(lvsum);
            end loop;
        end if;
        lvs_vector <= lvs_result;

        -- vclzlsbb and vctzlsbb
        vcz_bits := (others => '0');
        for i in 0 to 15 loop
            vcz_bits(i) := b_in(i*8);
        end loop;
        if e_in.invert_a = '0' then
            vcz_bits := bit_reverse(vcz_bits);
        end if;
        vcz_onehot := std_ulogic_vector(- signed(vcz_bits)) and vcz_bits;
        vcz_result := (others => '0');
        vcz_result(64+4) := not (or(vcz_onehot));
        vcz_result(64+3) := or(vcz_onehot(15 downto 8));
        vcz_result(64+2) := or(vcz_onehot(15 downto 12)) or or(vcz_onehot(7 downto 4));
        vcz_result(64+1) := or(vcz_onehot(15 downto 14)) or or(vcz_onehot(11 downto 10)) or
                            or(vcz_onehot(7 downto 6)) or or(vcz_onehot(3 downto 2));
        vcz_result(64) := vcz_onehot(15) or vcz_onehot(13) or vcz_onehot(11) or vcz_onehot(9) or
                          vcz_onehot(7) or vcz_onehot(5) or vcz_onehot(3) or vcz_onehot(1);

        if e_in.sub_select(0) = '0' then
            vmisc_result <= lvs_result;
        else
            vmisc_result <= vcz_result;
        end if;

        -- Signals to 32-bit multipliers
        if e_in.sub_select(0) = '0' then
            mult_hi_in.data1 <= 32x"0" & e_in.vra_hi(63 downto 32);
            mult_hi_in.data2 <= 32x"0" & e_in.vrb_hi(63 downto 32);
            mult_lo_in.data1 <= 32x"0" & e_in.vra_lo(63 downto 32);
            mult_lo_in.data2 <= 32x"0" & e_in.vrb_lo(63 downto 32);
        else
            mult_hi_in.data1 <= 32x"0" & e_in.vra_hi(31 downto 0);
            mult_hi_in.data2 <= 32x"0" & e_in.vrb_hi(31 downto 0);
            mult_lo_in.data1 <= 32x"0" & e_in.vra_lo(31 downto 0);
            mult_lo_in.data2 <= 32x"0" & e_in.vrb_lo(31 downto 0);
        end if;
        mult_hi_in.is_signed <= e_in.is_signed;
        mult_lo_in.is_signed <= e_in.is_signed;
        mult_hi_in.subtract <= '0';
        mult_lo_in.subtract <= '0';
        mult_hi_in.addend <= (others => '0');
        mult_lo_in.addend <= (others => '0');
    end process;

    vector_rot: process(all)
        variable shdata, shcnt : std_ulogic_vector(63 downto 0);
        variable is_rotate : std_ulogic;
        variable is_right_shift : std_ulogic;
        variable lbyte, rbyte : std_ulogic_vector(7 downto 0);
        variable twobytes : std_ulogic_vector(15 downto 0);
        variable bitshift : unsigned(2 downto 0);
        variable byteshift : unsigned(2 downto 0);
        variable lenm1 : unsigned(2 downto 0);
        variable b : unsigned(2 downto 0);
        variable j, k, lsbi : integer;
        variable resultb, selb : std_ulogic_vector(7 downto 0);
    begin
        shdata := vs1.bits(191 downto 128);
        shcnt := vs1.shcnt;
        is_rotate := vs1.is_rotate;
        is_right_shift := vs1.is_right_shift;
        for i in 0 to 7 loop
            lbyte := (others => '0');
            rbyte := (others => '0');
            bitshift := "000";
            byteshift := "000";
            lenm1 := "000";
            k := 0;
            -- Compute a byte to the left (for right shifts)
            -- and a byte to the right (for left shifts and rotates)
            case vs1.lg_length(1 downto 0) is
                when "00" =>
                    lsbi := i;
                    bitshift := unsigned(shcnt(i*8 + 2 downto i*8));
                    if is_rotate = '1' then
                        rbyte := shdata(i*8 + 7 downto i*8);
                    end if;
                when "01" =>
                    k := i mod 2;
                    lsbi := i - k;
                    lenm1 := "001";
                    bitshift := unsigned(shcnt(lsbi*8 + 2 downto lsbi*8));
                    byteshift(0) := shcnt(lsbi*8 + 3);
                    if k = 0 then
                        lbyte := shdata(i*8 + 15 downto i*8 + 8);
                        if is_rotate = '1' then
                            rbyte := lbyte;
                        end if;
                    else
                        rbyte := shdata(i*8 - 1 downto i*8 - 8);
                    end if;
                when "10" =>
                    k := i mod 4;
                    lsbi := i - k;
                    lenm1 := "011";
                    bitshift := unsigned(shcnt(lsbi*8 + 2 downto lsbi*8));
                    byteshift(1 downto 0) := unsigned(shcnt(lsbi*8 + 4 downto lsbi*8 + 3));
                    if k = 0 then
                        if is_rotate = '1' then
                            rbyte := shdata(i*8 + 31 downto i*8 + 24);
                        end if;
                    else
                        rbyte := shdata(i*8 - 1 downto i*8 - 8);
                    end if;
                    if k < 3 then
                        lbyte := shdata(i*8 + 15 downto i*8 + 8);
                    end if;
                when others =>
                    k := i mod 8;
                    lsbi := i - k;
                    lenm1 := "111";
                    bitshift := unsigned(shcnt(lsbi*8 + 2 downto lsbi*8));
                    byteshift := unsigned(shcnt(lsbi*8 + 5 downto lsbi*8 + 3));
                    if k = 0 then
                        if is_rotate = '1' then
                            rbyte := shdata(i*8 + 63 downto i*8 + 56);
                        end if;
                    else
                        rbyte := shdata(i*8 - 1 downto i*8 - 8);
                    end if;
                    if k < 7 then
                        lbyte := shdata(i*8 + 15 downto i*8 + 8);
                    end if;
            end case;
            -- Shift (lbyte || data || rbyte) left or right by 0 - 7 bits
            if is_X(bitshift) then
                resultb := (others => 'X');
            else
                j := to_integer(bitshift);
                if is_right_shift = '0' then
                    twobytes := shdata(i*8 + 7 downto i*8) & rbyte;
                    resultb := twobytes(15 - j downto 8 - j);
                else
                    twobytes := lbyte & shdata(i*8 + 7 downto i*8);
                    resultb := twobytes(7 + j downto j);
                end if;
            end if;
            vshiftbits(i*8 + 7 downto i*8) <= resultb;
            -- Work out the selection vector to cause the permutation
            -- machinery to do the byte-level part of the shift/rotate
            -- This byte of the selection vector indicates which byte
            -- of vshiftbits goes into this byte of the result.
            if is_X(byteshift) then
                selb := (others => 'X');
            else
                selb := (others => '0');
                selb(6) := vs1.perm_counter(1);
                if is_right_shift = '0' then
                    if k >= to_integer(byteshift) or is_rotate = '1' then
                        b := (to_unsigned(i, 3) - byteshift) and lenm1;
                        selb(7) := '1';
                        selb(5 downto 3) := std_ulogic_vector(to_unsigned(lsbi, 3)) or
                                            std_ulogic_vector(b);
                    end if;
                else
                    if k <= to_integer(lenm1 - byteshift) then
                        b := to_unsigned(i, 3) + byteshift;
                        selb(7) := '1';
                        selb(5 downto 3) := std_ulogic_vector(to_unsigned(lsbi, 3)) or
                                            std_ulogic_vector(b);
                    end if;
                end if;
            end if;
            vshiftsel(i*8 + 7 downto i*8) <= selb;
        end loop;
    end process;

    vector_1r: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                vs1 <= vec_stage1_init;
            elsif flush_in = '1' then
                vs1.e.valid <= '0';
                vs1.e.write_enable <= '0';
                vs1.e.write_cr_enable <= '0';
                vs1.busy <= '0';
                vs1.do_vperm <= '0';
            else
                vs1 <= vs1in;
            end if;
        end if;
    end process;

    vector_1: process(all)
        variable v : vec_stage1_type;
    begin
        v := vs1;
        v.wdat_valid := '0';
        mult_hi_in.valid <= '0';
        mult_lo_in.valid <= '0';

        if vs1.busy = '1' then
            -- can only be vperm or vbpermq, or a vector shift or rotate
            v.perm_counter := vs1.perm_counter + 1;
            if vs1.perm_counter >= 2 then
                v.busy := '0';
                v.e.valid := '1';
                v.e.write_enable := '1';
            end if;
            -- rotate vs1.bits right 64 bits
            v.bits := vs1.bits(63 downto 0) & vs1.bits(255 downto 64);
            -- for vector shift/rotate, put rotated byte data into
            -- LS doubleword of vs1.bits, and update vs1.sel
            if vs1.is_shift = '1' then
                v.bits(63 downto 0) := vshiftbits;
                if vs1.perm_counter(1) = '0' then
                    v.sel(63 downto 0) := vshiftsel;
                else
                    v.sel(127 downto 64) := vshiftsel;
                end if;
            end if;
            v.shcnt := vs1.bits(127 downto 64);

        elsif e_in.stall = '0' then
            v := vec_stage1_init;
            v.e.valid := e_in.valid;
            v.e.instr_tag := e_in.instr_tag;

            v.e.write_enable := v.e.valid and e_in.write_reg_enable;
            v.e.write_reg := e_in.write_reg;

            v.e.write_cr_enable := v.e.valid and e_in.output_cr;
            v.e.write_cr_mask := num_to_fxm(6);
            v.e.write_cr_data := x"000000" & vec_cr6 & x"0";
            v.wdat_valid := e_in.valid;

            v.rsel := e_in.result_sel;
            v.vadd_data := vadd_result;
            v.vlog_data := vlog_result;
            v.vmisc_data := vmisc_result;
            v.vgbbd_data := vgbbd_result;

            if e_in.opv(OP_VPERM) = '1' then
                v.busy := e_in.valid;
                v.do_vperm := e_in.valid;
                v.e.valid := '0';
                v.e.write_enable := '0';
                v.is_vbpermq := e_in.sub_select(0);
            end if;
            if e_in.opv(OP_VSHIFT) = '1' then
                v.busy := e_in.valid;
                v.do_vperm := e_in.valid;
                v.e.valid := '0';
                v.e.write_enable := '0';
                v.is_shift := '1';
            end if;
            if e_in.opv(OP_VMUL) = '1' then
                mult_hi_in.valid <= e_in.valid;
                mult_lo_in.valid <= e_in.valid;
                v.do_mult_32 := e_in.valid;
            end if;
            v.is_mtvscr := e_in.opv(OP_MTVSCR);

            if e_in.sub_select(2) = '1' then
                -- vector shift or rotate
                v.bits := a_in & b_in;
                v.sel := (others => '0');
                v.perm_counter := "01";
            elsif e_in.sub_select(0) = '1' then
                -- vbpermq, data in VRA and select in VRB
                v.bits := 128x"0" & a_in;
                v.sel := not b_in;
                v.perm_counter := "10";
            elsif e_in.sub_select(1) = '1' then
                -- vsldoi, data in VRA||VRB, select from shift count
                v.bits := a_in & b_in;
                v.sel := not lvs_vector(124 downto 0) & "000";
                v.perm_counter := "00";
            else
                -- vperm, data in VRA||VRB and select in VRC
                v.bits := a_in & b_in;
                v.sel := c_in(124 downto 0) & "000";
                if e_in.invert_out = '1' then
                    v.sel := not c_in(124 downto 0) & "000";
                end if;
                v.perm_counter := "00";
            end if;
            v.shcnt := b_in(63 downto 0);
            v.is_rotate := e_in.sub_select(0);
            v.is_right_shift := e_in.sub_select(1);
            v.lg_length := e_in.lg_length;

        else
            v.do_vperm := '0';
        end if;

        -- update state
        vs1in <= v;
    end process;

    vector_2r: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or flush_in = '1' then
                vs2 <= vec_stage2_init;
            else
                vs2 <= vs2in;
            end if;
            if rst = '1' then
                vscr_sat <= '0';
                vscr_nj <= '0';
            elsif do_mtvscr = '1' then
                vscr_sat <= vs2in.e.write_data(0);
                vscr_nj <= vs2in.e.write_data(16);
            end if;
        end if;
    end process;

    vector_2: process(all)
        variable v : vec_stage2_type;
        variable j : integer;
        variable b : std_ulogic_vector(7 downto 0);
        variable vpd : std_ulogic_vector(127 downto 0);
    begin
        v.e.write_data := vs2.e.write_data;

        v.e.valid := vs1.e.valid;
        v.e.instr_tag := vs1.e.instr_tag;
        v.e.write_enable := vs1.e.write_enable;
        v.e.write_reg := vs1.e.write_reg;
        v.e.write_cr_enable := vs1.e.write_cr_enable;
        v.e.write_cr_mask := vs1.e.write_cr_mask;
        v.e.write_cr_data := vs1.e.write_cr_data;

        if vs1.do_vperm = '1' then
            -- vperm, vpermr, vector shift/rotate
            vpd := (others => '0');
            if vs1.wdat_valid = '0' then
                vpd := vs2.e.write_data;
            end if;
            for i in 0 to 15 loop
                if vs1.sel(i*8 + 7 downto i*8 + 6) = std_ulogic_vector(vs1.perm_counter) then
                    j := to_integer(unsigned(vs1.sel(i*8 + 5 downto i*8 + 3))) * 8;
                    b := vs1.bits(j + 7 downto j);
                    if vs1.is_vbpermq = '1' then
                        j := to_integer(unsigned(vs1.sel(i*8 + 2 downto i*8)));
                        vpd(i + 64) := b(j);
                    else
                        vpd(i*8 + 7 downto i*8) := b;
                    end if;
                end if;
            end loop;
            v.e.write_data := vpd;

        elsif vs1.wdat_valid = '1' then
            case vs1.rsel is
                when ADD =>
                    v.e.write_data := vs1.vadd_data;
                when LOG =>
                    v.e.write_data := vs1.vlog_data;
                when MUL =>
                    v.e.write_data(127 downto 64) := mult_hi_out.result(63 downto 0);
                    v.e.write_data(63 downto 0)   := mult_lo_out.result(63 downto 0);
                when VGBB =>
                    v.e.write_data := vs1.vgbbd_data;
                when MSC =>
                    v.e.write_data := vs1.vmisc_data;
                when others =>
                    v.e.write_data := (others => '0');
            end case;
        end if;

        if e_in.stall = '1' then
            v.e.valid := '0';
            v.e.write_enable := '0';
            v.e.write_cr_enable := '0';
        end if;
        vs2in <= v;

        do_mtvscr <= vs1.e.valid and vs1.is_mtvscr and not e_in.stall;
    end process;

    e_out.busy <= vs1.busy;
    e_out.v2stall <= '0';

    w_out <= vs2.e;

end architecture behaviour;
