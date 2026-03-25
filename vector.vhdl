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
        bits     : std_ulogic_vector(255 downto 0);
        sel      : std_ulogic_vector(127 downto 0);

        perm_counter : unsigned(1 downto 0);
        wdat_valid : std_ulogic;
        do_vperm : std_ulogic;
        is_vbpermq : std_ulogic;

        vgbbd_data : std_ulogic_vector(127 downto 0);
        do_vgbbd   : std_ulogic;
    end record;
    constant vec_stage1_init : vec_stage1_type :=
        (e => VectorToWritebackInit,
         bits => (others => '0'), sel => (others => '0'),
         perm_counter => "00",
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
    signal vec_result : std_ulogic_vector(127 downto 0);
    signal vlog_result : std_ulogic_vector(127 downto 0);
    signal vmisc_result : std_ulogic_vector(127 downto 0);
    signal vec_cr6 : std_ulogic_vector(3 downto 0);

begin

    -- Data path
    a_in <= e_in.vra_hi & e_in.vra_lo;
    b_in <= e_in.vrb_hi & e_in.vrb_lo;
    c_in <= e_in.vrc_hi & e_in.vrc_lo;

    vector_dp: process(all)
        variable mtvsr_result : std_ulogic_vector(63 downto 0);
        variable negative : std_ulogic;
        variable a_inv, b_inv : std_ulogic_vector(127 downto 0);
        variable splti_result : std_ulogic_vector(127 downto 0);
        variable vcmp_eqb : std_ulogic_vector(15 downto 0);
        variable vcmp_res : std_ulogic_vector(15 downto 0);
        variable vcmp_crf : std_ulogic_vector(3 downto 0);
        variable size_mask : unsigned(1 downto 0);
        variable nib : unsigned(3 downto 0);
        variable lvsum : unsigned(4 downto 0);
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
                -- also used to initialize write_data[_lo] to zero by vbpermq
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
            when "110" =>
                -- vector comparison result
                for i in 0 to 15 loop
                    vlog_result(i*8 + 7 downto i*8) <= (others => vcmp_res(i));
                end loop;
                vec_cr6 <= vcmp_crf;
            when "111" =>
                -- splat-immediate result
                size_mask := unsigned(e_in.length(1 downto 0)) - 1;
                for i in 0 to 15 loop
                    -- we can always use either byte 0 or byte 1, since bytes
                    -- 2 and 3 are the same as byte 1
                    if (to_unsigned(i mod 4, 2) and size_mask) /= "00" then
                        splti_result(i*8 + 7 downto i*8) := e_in.vrb_hi(15 downto 8);
                    else
                        splti_result(i*8 + 7 downto i*8) := e_in.vrb_hi(7 downto 0);
                    end if;
                end loop;
                vlog_result <= splti_result;
            when others =>
        end case;

        -- Other miscellaneous operations
        -- Just lvsl/lvsr so far
        vmisc_result <= (others => '0');
        nib := unsigned(e_in.vra_hi(3 downto 0)) + unsigned(e_in.vrb_hi(3 downto 0));
        if e_in.invert_out = '0' then
            -- lvsl
            for i in 0 to 15 loop
                lvsum := to_unsigned(15 - i, 5) + resize(nib, 5);
                vmisc_result(i*8 + 4 downto i*8) <= std_ulogic_vector(lvsum);
            end loop;
        else
            -- lvsr
            for i in 0 to 15 loop
                lvsum := to_unsigned(31 - i, 5) - resize(nib, 5);
                vmisc_result(i*8 + 4 downto i*8) <= std_ulogic_vector(lvsum);
            end loop;
        end if;
    end process;

    vec_result <= vlog_result when e_in.result_sel = LOG else
                  vmisc_result when e_in.result_sel = MSC else
                  (others => '0');

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

        if vs1.busy = '1' then
            -- can only be vperm or vbpermq, at present
            v.perm_counter := vs1.perm_counter + 1;
            if vs1.perm_counter >= 2 then
                v.busy := '0';
                v.e.valid := '1';
                v.e.write_enable := '1';
            end if;
            -- rotate vs1.bits right 64 bits
            v.bits := vs1.bits(63 downto 0) & vs1.bits(255 downto 64);

        elsif e_in.stall = '0' then
            v := vec_stage1_init;
            v.e.valid := e_in.valid;
            v.e.instr_tag := e_in.instr_tag;

            v.e.write_enable := v.e.valid and e_in.write_reg_enable;
            v.e.write_reg := e_in.write_reg;
            v.e.write_data := vec_result(127 downto 64);
            v.e.write_data_lo := vec_result(63 downto 0);

            v.e.write_cr_enable := v.e.valid and e_in.output_cr;
            v.e.write_cr_mask := num_to_fxm(6);
            v.e.write_cr_data := x"000000" & vec_cr6 & x"0";
            v.wdat_valid := e_in.valid;

            if e_in.opv(OP_VPERM) = '1' then
                v.busy := e_in.valid;
                v.do_vperm := e_in.valid;
                v.e.valid := '0';
                v.e.write_enable := '0';
                -- abuse is_32bit flag to indicate vbpermq
                v.is_vbpermq := e_in.is_32bit;
            end if;
            if e_in.opv(OP_COMPUTE) = '1' then
                if e_in.sub_select = "101" then
                    v.do_vgbbd := '1';
                end if;
            end if;
            if e_in.is_32bit = '1' then
                -- vbpermq, data in VRA and select in VRB
                v.bits := 128x"0" & a_in;
                v.sel := not b_in;
                v.perm_counter := "10";
            else
                -- vperm, data in VRA||VRB and select in VRC
                v.bits := a_in & b_in;
                v.sel := c_in(124 downto 0) & "000";
                if e_in.invert_out = '1' then
                    v.sel := not c_in(124 downto 0) & "000";
                end if;
                v.perm_counter := "00";
            end if;

            for i in 0 to 7 loop
                for j in 0 to 7 loop
                    v.vgbbd_data(i*8 + j) := b_in(j*8 + i);
                    v.vgbbd_data(i*8 + j + 64) := b_in(j*8 + i + 64);
                end loop;
            end loop;

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
        end if;
    end process;

    vector_2: process(all)
        variable v : vec_stage2_type;
        variable j : integer;
        variable b : std_ulogic_vector(7 downto 0);
    begin
        v.e.write_data := vs2.e.write_data;
        v.e.write_data_lo := vs2.e.write_data_lo;

        v.e.valid := vs1.e.valid;
        v.e.instr_tag := vs1.e.instr_tag;
        v.e.write_enable := vs1.e.write_enable;
        v.e.write_reg := vs1.e.write_reg;
        v.e.write_cr_enable := vs1.e.write_cr_enable;
        v.e.write_cr_mask := vs1.e.write_cr_mask;
        v.e.write_cr_data := vs1.e.write_cr_data;
        if vs1.wdat_valid = '1' then
            v.e.write_data := vs1.e.write_data;
            v.e.write_data_lo := vs1.e.write_data_lo;
        end if;

        if vs1.do_vperm = '1' then
            -- vperm, vpermr
            for i in 0 to 15 loop
                if vs1.sel(i*8 + 7 downto i*8 + 6) = std_ulogic_vector(vs1.perm_counter) then
                    j := to_integer(unsigned(vs1.sel(i*8 + 5 downto i*8 + 3))) * 8;
                    b := vs1.bits(j + 7 downto j);
                    if vs1.is_vbpermq = '1' then
                        j := to_integer(unsigned(vs1.sel(i*8 + 2 downto i*8)));
                        v.e.write_data(i) := b(j);
                    else
                        if i < 8 then
                            v.e.write_data_lo(i*8 + 7 downto i*8) := b;
                        else
                            v.e.write_data((i-8)*8 + 7 downto (i-8)*8) := b;
                        end if;
                    end if;
                end if;
            end loop;

        elsif vs1.do_vgbbd = '1' then
            v.e.write_data := vs1.vgbbd_data(127 downto 64);
            v.e.write_data_lo := vs1.vgbbd_data(63 downto 0);

        end if;

        if e_in.stall = '1' then
            v.e.valid := '0';
            v.e.write_enable := '0';
            v.e.write_cr_enable := '0';
        end if;
        vs2in <= v;
    end process;

    e_out.busy <= vs1.busy;
    e_out.v2stall <= '0';

    w_out <= vs2.e;

end architecture behaviour;
