library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Simple, slow, small multiplier, does one at a time
-- Not suitable for use with the FPU since it expects the multiplier to be pipelined.

library work;
use work.common.all;

entity multiply is
    port (
        clk   : in std_logic;

        m_in  : in MultiplyInputType;
        m_out : out MultiplyOutputType
        );
end entity multiply;

architecture behaviour of multiply is
    type reg_type is record
        a : std_ulogic_vector(63 downto 0);
        b : std_ulogic_vector(63 downto 0);
        add : std_ulogic_vector(63 downto 0);
        sum : std_ulogic_vector(127 downto 0);
        carry : std_ulogic;
        is_32bit : std_ulogic;
        not_result : std_ulogic;
        count : integer range 0 to 15;
        running : std_ulogic;
        done : std_ulogic;
    end record;
    constant reg_type_init : reg_type := (a => (others => '0'), b => (others => '0'),
                                          add => (others => '0'), sum => (others => '0'),
                                          carry => '0', is_32bit => '0', not_result => '0',
                                          count => 0, running => '0', done => '0');

    signal r, rin : reg_type := reg_type_init;
    signal overflow : std_ulogic;
    signal ovf_in   : std_ulogic;
begin
    multiply_0: process(clk)
    begin
        if rising_edge(clk) then
            r <= rin;
            overflow <= ovf_in;
            if rin.running = '1' or rin.done = '1' then
                report "running = " & std_ulogic'image(rin.running) & " done = " & std_ulogic'image(rin.done) & " a=" & to_hstring(rin.a) & " b=" & to_hstring(rin.b) & " sum=" & to_hstring(rin.sum) & " add=" & to_hstring(rin.add) & " carry=" & std_ulogic'image(rin.carry);
            end if;
        end if;
    end process;

    multiply_1: process(all)
        variable v : reg_type;
        variable t0, t1, t2, t3 : std_ulogic_vector(65 downto 0);
        variable t01, t23, t03 : std_ulogic_vector(67 downto 0);
        variable sum : std_ulogic_vector(68 downto 0);
        variable d : std_ulogic_vector(127 downto 0);
	variable ov : std_ulogic;
    begin
        v := r;

        v.done := '0';
        if m_in.valid = '1' then
            v.a := m_in.data1;
            v.b := m_in.data2;
            v.sum := m_in.addend(63 downto 0) & 64x"0";
            v.add := m_in.addend(127 downto 64);
            v.carry := '0';
            v.is_32bit := m_in.is_32bit;
            v.not_result := m_in.not_result;
            v.count := 0;
            v.running := '1';
        elsif r.running = '1' then
            t0 := (others => '0');
            t1 := (others => '0');
            t2 := (others => '0');
            t3 := (others => '0');
            if r.b(0) = '1' then
                t0 := "00" & r.a;
            end if;
            t0(64) := r.carry;
            if r.b(1) = '1' then
                t1 := '0' & r.a & '0';
            end if;
            if r.b(2) = '1' then
                t2 := "00" & r.a;
            end if;
            if r.b(3) = '1' then
                t3 := '0' & r.a & '0';
            end if;
            t01 := "00" & std_ulogic_vector(unsigned(t0) + unsigned(t1));
            t23 := std_ulogic_vector(unsigned(t2) + unsigned(t3)) & "00";
            t03 := std_ulogic_vector(unsigned(t01) + unsigned(t23));
            sum := std_ulogic_vector(unsigned('0' & t03) +
                                     unsigned('0' & r.add(3 downto 0) & r.sum(127 downto 64)));
            v.carry := sum(68);
            v.sum := sum(67 downto 0) & v.sum(63 downto 4);
            v.add := "0000" & r.add(63 downto 4);
            v.b := "0000" & r.b(63 downto 4);

            if (r.is_32bit = '0' and r.count = 15) or (r.is_32bit = '1' and r.count = 7) then
                v.count := 0;
                v.running := '0';
                v.done := '1';
            else
                v.count := r.count + 1;
            end if;
        end if;

        if r.is_32bit = '0' then
            d := r.sum;
            ov := (or d(127 downto 63)) and not (and d(127 downto 63));
        else
            d := 64x"0" & r.sum(95 downto 32);
            ov := (or d(63 downto 31)) and not (and d(63 downto 31));
        end if;
        ovf_in <= ov;

        m_out.result <= d xor (127 downto 0 => r.not_result);
        m_out.overflow <= overflow;
        m_out.valid <= r.done;

        rin <= v;
    end process;
end architecture behaviour;
