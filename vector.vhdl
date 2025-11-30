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
        vra      : std_ulogic_vector(127 downto 0);
        vrb      : std_ulogic_vector(127 downto 0);
        vrc      : std_ulogic_vector(127 downto 0);
    end record;
    constant vec_stage1_init : vec_stage1_type :=
        (e => VectorToWritebackInit,
         vra => (others => '0'), vrb => (others => '0'), vrc => (others => '0'),
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
    signal vec_valid : std_ulogic;
    signal vec_result : std_ulogic_vector(127 downto 0);
    signal vec_cr6 : std_ulogic_vector(3 downto 0);

begin

    -- Data path
    a_in <= e_in.vra_hi & e_in.vra_lo;
    b_in <= e_in.vrb_hi & e_in.vrb_lo;
    c_in <= e_in.vrc_hi & e_in.vrc_lo;
    vec_valid <= e_in.valid;
    vec_cr6 <= (others => '0');

    vector_dp: process(all)
        variable mtvsr_result : std_ulogic_vector(63 downto 0);
        variable negative : std_ulogic;
        variable a_inv, b_inv : std_ulogic_vector(127 downto 0);
        variable vlog_result : std_ulogic_vector(127 downto 0);
    begin
        vec_result <= (others => '0');
        case e_in.sub_select is
            when "000" =>
                -- mtvsr*
                vec_result(127 downto 64) <= e_in.vra_hi;
                vec_result(63 downto 0) <= e_in.vrb_hi;
                if e_in.is_32bit = '1' then
                    -- mtvsr{wa,wz,ws} - select the A input, truncated
                    -- to 32 bits and possibly sign-extended or splatted
                    -- abuse invert_out field of decode table to indicate splat.
                    mtvsr_result := e_in.vra_hi;
                    if e_in.invert_out = '1' then
                        mtvsr_result(63 downto 32) := e_in.vra_hi(31 downto 0);
                        vec_result(63 downto 0) <= mtvsr_result;
                    else
                        negative := e_in.is_signed and e_in.vra_hi(31);
                        mtvsr_result(63 downto 32) := (others => negative);
                    end if;
                    vec_result(127 downto 64) <= mtvsr_result;
                end if;
            when "001" =>
                -- mfvsr*; mfvsrld has invert_out = 1, mfvsrwz has is_32bit = 1
                if e_in.invert_out = '1' then
                    vec_result(127 downto 64) <= e_in.vrc_lo;
                else
                    vec_result(127 downto 64) <= e_in.vrc_hi;
                end if;
                if e_in.is_32bit = '1' then
                    vec_result(127 downto 96) <= (others => '0');
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
                vlog_result := a_inv and b_inv;
                if e_in.invert_out = '1' then
                    vlog_result := not vlog_result;
                end if;
                vec_result <= vlog_result;
            when "011" =>
                -- vxor, veqv
                a_inv := a_in;
                if e_in.invert_a = '1' then
                    a_inv := not a_in;
                end if;
                vec_result <= a_inv xor b_in;
            when "100" =>
                -- xxpermdi
                vec_result <= e_in.vra_hi & e_in.vrb_hi;
                if e_in.insn(9) = '1' then
                    vec_result(127 downto 64) <= e_in.vra_lo;
                end if;
                if e_in.insn(8) = '1' then
                    vec_result(63 downto 0) <= e_in.vrb_lo;
                end if;
            when others =>
        end case;
    end process;

    vector_1r: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                vs1 <= vec_stage1_init;
            elsif e_in.stall = '0' then
                vs1 <= vs1in;
            end if;
        end if;
    end process;

    vector_1: process(all)
        variable v : vec_stage1_type;
    begin
        v := vec_stage1_init;
        v.e.valid := e_in.valid and not flush_in;
        v.e.instr_tag := e_in.instr_tag;

        v.e.write_enable := v.e.valid and e_in.write_reg_enable;
        v.e.write_reg := e_in.write_reg;
        v.e.write_data := vec_result(127 downto 64);
        v.e.write_data_lo := vec_result(63 downto 0);

        v.e.write_cr_enable := v.e.valid and e_in.output_cr;
        v.e.write_cr_mask := num_to_fxm(6);
        v.e.write_cr_data := x"000000" & vec_cr6 & x"0";

        -- update state
        vs1in <= v;
    end process;

    vector_2r: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                vs2 <= vec_stage2_init;
            else
                vs2 <= vs2in;
            end if;
        end if;
    end process;

    vector_2: process(all)
        variable v : vec_stage2_type;
    begin
        v.e := vs1.e;
        if e_in.stall = '1' or flush_in = '1' then
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
