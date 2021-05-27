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
        e        : VectorToExecute1Type;
        w        : VectorToWritebackType;
    end record;
    constant vec_state_init : vec_state := (e => VectorToExecute1Init, w => VectorToWritebackInit);

    signal vst, vst_in : vec_state;

    type byte_comparison_t is array(0 to 7) of boolean;

    signal a_in       : std_ulogic_vector(63 downto 0);
    signal b_in       : std_ulogic_vector(63 downto 0);
    signal c_in       : std_ulogic_vector(63 downto 0);
    signal vec_valid  : std_ulogic;
    signal vec_result : std_ulogic_vector(63 downto 0);
    signal vec_cr6    : std_ulogic_vector(3 downto 0);

begin

    -- Data path
    a_in <= e_in.vra;
    b_in <= e_in.vrb;
    c_in <= e_in.vrc;
    vec_valid <= e_in.valid;
    vec_result <= (others => '0');
    vec_cr6 <= (others => '0');

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
        variable v : vec_state;
    begin
        v := vst;
        v.e.busy := '0';
        v.e.in_progress := '0';
        v.w.valid := '0';
        v.w.instr_tag := e_in.instr_tag;

        v.w.write_enable := v.w.valid and e_in.write_reg_enable;
        v.w.write_reg := e_in.write_reg;
        v.w.write_data := vec_result;

        -- write back CR6 result on the second half
        v.w.write_cr_enable := vec_valid and e_in.output_cr and e_in.second;
        v.w.write_cr_mask := num_to_fxm(6);
        v.w.write_cr_data := x"000000" & vec_cr6 & x"0";

        w_out <= vst.w;
        e_out <= vst.e;

        -- update state
        vst_in <= v;
    end process;
end architecture behaviour;
