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
        vec_result      : out std_ulogic_vector(63 downto 0)
        );
end entity vector_unit;

architecture behaviour of vector_unit is
    
    -- State for vector instructions
    type vec_state is record
        a0       : std_ulogic_vector(63 downto 0);
        b0       : std_ulogic_vector(63 downto 0);
        perm_sel : std_ulogic_vector(63 downto 0);
    end record;
    constant vec_state_init : vec_state := (others => (others => '0'));

    signal vst, vst_in : vec_state;

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
        variable data         : std_ulogic_vector(255 downto 0);
    begin
        v := vst;
        if e_in.valid = '1' and e_in.second = '0' then
            v.a0 := a_in;
            v.b0 := b_in;
        end if;
        if e_in.valid = '1' then
            if e_in.insn(4) = '0' then
                -- vperm
                v.perm_sel := not c_in;
            else
                -- vpermr
                v.perm_sel := c_in;
            end if;
        end if;

        data := vst.a0 & a_in & vst.b0 & b_in;
        for i in 0 to 7 loop
            k := i * 8;
            m := to_integer(unsigned(vst.perm_sel(k + 4 downto k)));
            n := m * 8;
            vec_result(k + 7 downto k) <= data(n + 7 downto n);
        end loop;

        -- update state
        vst_in <= v;
    end process;
end architecture behaviour;
