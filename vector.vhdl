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
        writes   : std_ulogic;
        wr_reg   : gspr_index_t;
        wr_cr    : std_ulogic;
        op       : insn_type_t;
        itag     : instr_tag_t;
        part1    : std_ulogic;
        part2    : std_ulogic;
        e        : VectorToExecute1Type;
        w        : VectorToWritebackType;
    end record;
    constant vec_state_init : vec_state := (e => VectorToExecute1Init, w => VectorToWritebackInit,
                                            writes => '0', wr_reg => (others => '0'), wr_cr => '0',
                                            op => OP_ILLEGAL, itag => instr_tag_init,
                                            part1 => '0', part2 => '0',
                                            others => (others => '0'));

    signal vst, vst_in : vec_state;

    signal a_in         : std_ulogic_vector(63 downto 0);
    signal b_in         : std_ulogic_vector(63 downto 0);
    signal c_in         : std_ulogic_vector(63 downto 0);
    signal a1_in        : std_ulogic_vector(63 downto 0);
    signal b1_in        : std_ulogic_vector(63 downto 0);
    signal vperm_result : std_ulogic_vector(63 downto 0);
    signal perm_data    : std_ulogic_vector(255 downto 0);
    signal vec_result   : std_ulogic_vector(63 downto 0);
    signal vec_cr6      : std_ulogic_vector(3 downto 0);

begin

    -- Data path
    a_in <= e_in.vra;
    b_in <= e_in.vrb;
    c_in <= e_in.vrc;
    vec_cr6 <= (others => '0');

    a1_in <= a_in when vst.part1 = '1' else vst.a1;
    b1_in <= b_in when vst.part1 = '1' else vst.b1;

    -- vperm
    perm_data <= vst.a0 & a1_in & vst.b0 & b1_in;
    vperm: for i in 0 to 7 generate
        vperm_result(i*8 + 7 downto i*8) <=
            perm_data(to_integer(unsigned(vst.perm_sel(i*8 + 4 downto i*8))) * 8 + 7 downto
                      to_integer(unsigned(vst.perm_sel(i*8 + 4 downto i*8))) * 8);
    end generate;

    vec_result <= vperm_result;

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
                when others =>
                    v.perm_sel := (others => '0');
            end case;
        end if;

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
