library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.common.all;
use work.crhelpers.all;

entity writeback is
    port (
        clk          : in std_ulogic;
        rst          : in std_ulogic;

        e_in         : in Execute1ToWritebackType;
        l_in         : in Loadstore1ToWritebackType;
        fp_in        : in FPUToWritebackType;

        w_out        : out WritebackToRegisterFileType;
        c_out        : out WritebackToCrFileType;
        f_out        : out WritebackToFetch1Type;

        -- PMU event bus
        events       : out WritebackEventType;

        flush_out    : out std_ulogic;
        interrupt_out: out WritebackToExecute1Type;
        complete_out : out instr_tag_t
        );
end entity writeback;

architecture behaviour of writeback is

begin
    writeback_0: process(clk)
        variable x : std_ulogic_vector(0 downto 0);
        variable y : std_ulogic_vector(0 downto 0);
        variable w : std_ulogic_vector(0 downto 0);
    begin
        if rising_edge(clk) then
            -- Do consistency checks only on the clock edge
            x(0) := e_in.valid;
            y(0) := l_in.valid;
            w(0) := fp_in.valid;
            assert (to_integer(unsigned(x)) + to_integer(unsigned(y)) +
                    to_integer(unsigned(w))) <= 1 severity failure;

            x(0) := e_in.write_enable;
            y(0) := l_in.write_enable;
            w(0) := fp_in.write_enable;
            assert (to_integer(unsigned(x)) + to_integer(unsigned(y)) +
                    to_integer(unsigned(w))) <= 1 severity failure;

            w(0) := e_in.write_cr_enable;
            x(0) := (e_in.write_enable and e_in.rc);
            y(0) := fp_in.write_cr_enable;
            assert (to_integer(unsigned(w)) + to_integer(unsigned(x)) +
                    to_integer(unsigned(y))) <= 1 severity failure;

            assert not (e_in.valid = '1' and e_in.instr_tag.valid = '0') severity failure;
            assert not (l_in.valid = '1' and l_in.instr_tag.valid = '0') severity failure;
            assert not (fp_in.valid = '1' and fp_in.instr_tag.valid = '0') severity failure;
        end if;
    end process;

    writeback_1: process(all)
        variable f    : WritebackToFetch1Type;
        variable cf: std_ulogic_vector(3 downto 0);
        variable zero : std_ulogic;
        variable sign : std_ulogic;
        variable scf  : std_ulogic_vector(3 downto 0);
        variable vec  : integer range 0 to 16#fff#;
        variable intr : std_ulogic;
    begin
        w_out <= WritebackToRegisterFileInit;
        c_out <= WritebackToCrFileInit;
        f := WritebackToFetch1Init;

        complete_out <= instr_tag_init;
        if e_in.valid = '1' then
            complete_out <= e_in.instr_tag;
        elsif l_in.valid = '1' then
            complete_out <= l_in.instr_tag;
        elsif fp_in.valid = '1' then
            complete_out <= fp_in.instr_tag;
        end if;
        events.instr_complete <= complete_out.valid;
        events.fp_complete <= fp_in.valid;

        intr := e_in.interrupt or l_in.interrupt or fp_in.interrupt;
        interrupt_out.valid <= intr;
        if l_in.interrupt = '1' then
            vec := l_in.intr_vec;
            interrupt_out.srr0 <= l_in.srr0;
            interrupt_out.srr1 <= l_in.srr1;
        elsif fp_in.interrupt = '1' then
            vec := fp_in.intr_vec;
            interrupt_out.srr0 <= fp_in.srr0;
            interrupt_out.srr1 <= fp_in.srr1;
        else
            vec := e_in.intr_vec;
            interrupt_out.srr0 <= e_in.last_nia;
            interrupt_out.srr1 <= e_in.srr1;
        end if;

        if intr = '0' then
            if e_in.write_enable = '1' then
                w_out.write_reg <= e_in.write_reg;
                w_out.write_data <= e_in.write_data;
                w_out.write_enable <= '1';
            end if;

            if e_in.write_cr_enable = '1' then
                c_out.write_cr_enable <= '1';
                c_out.write_cr_mask <= e_in.write_cr_mask;
                c_out.write_cr_data <= e_in.write_cr_data;
            end if;

            if fp_in.write_enable = '1' then
                w_out.write_reg <= fp_in.write_reg;
                w_out.write_data <= fp_in.write_data;
                w_out.write_enable <= '1';
            end if;

            if fp_in.write_cr_enable = '1' then
                c_out.write_cr_enable <= '1';
                c_out.write_cr_mask <= fp_in.write_cr_mask;
                c_out.write_cr_data <= fp_in.write_cr_data;
            end if;

            if l_in.write_enable = '1' then
                w_out.write_reg <= l_in.write_reg;
                w_out.write_data <= l_in.write_data;
                w_out.write_enable <= '1';
            end if;

            if l_in.rc = '1' then
                -- st*cx. instructions
                scf(3) := '0';
                scf(2) := '0';
                scf(1) := l_in.store_done;
                scf(0) := l_in.xerc.so;
                c_out.write_cr_enable <= '1';
                c_out.write_cr_mask <= num_to_fxm(0);
                c_out.write_cr_data(31 downto 28) <= scf;
            end if;

            -- Perform CR0 update for RC forms
            -- Note that loads never have a form with an RC bit, therefore this can test e_in.write_data
            if e_in.rc = '1' and e_in.write_enable = '1' then
                zero := not (or e_in.write_data(31 downto 0));
                if e_in.mode_32bit = '0' then
                    sign := e_in.write_data(63);
                    zero := zero and not (or e_in.write_data(63 downto 32));
                else
                    sign := e_in.write_data(31);
                end if;
                c_out.write_cr_enable <= '1';
                c_out.write_cr_mask <= num_to_fxm(0);
                cf(3) := sign;
                cf(2) := not sign and not zero;
                cf(1) := zero;
                cf(0) := e_in.xerc.so;
                c_out.write_cr_data(31 downto 28) <= cf;
            end if;
        end if;

        -- Outputs to fetch1
        f.redirect := e_in.redirect;
        f.br_nia := e_in.last_nia;
        f.br_last := e_in.br_last;
        f.br_taken := e_in.br_taken;
        if intr = '1' then
            f.redirect := '1';
            f.br_last := '0';
            f.redirect_nia := std_ulogic_vector(to_unsigned(vec, 64));
            f.virt_mode := '0';
            f.priv_mode := '1';
            -- XXX need an interrupt LE bit here, e.g. from LPCR
            f.big_endian := '0';
            f.mode_32bit := '0';
        else
            if e_in.abs_br = '1' then
                f.redirect_nia := e_in.br_offset;
            else
                f.redirect_nia := std_ulogic_vector(unsigned(e_in.last_nia) + unsigned(e_in.br_offset));
            end if;
            -- send MSR[IR], ~MSR[PR], ~MSR[LE] and ~MSR[SF] up to fetch1
            f.virt_mode := e_in.redir_mode(3);
            f.priv_mode := e_in.redir_mode(2);
            f.big_endian := e_in.redir_mode(1);
            f.mode_32bit := e_in.redir_mode(0);
        end if;

        f_out <= f;
        flush_out <= f_out.redirect;

    end process;
end;
