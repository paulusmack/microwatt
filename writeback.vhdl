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
        e_out        : out WritebackToExecute1Type;

        -- PMU event bus
        events       : out WritebackEventType;

        flush_out    : out std_ulogic;
        complete_out : out instr_tag_t;

        stall_ex     : out std_ulogic;
        stall_fpu    : out std_ulogic
        );
end entity writeback;

architecture behaviour of writeback is

    signal complete_tag : tag_number_t;
    signal next_tag     : tag_number_t;

    signal multihit     : std_ulogic;

begin
    writeback_0: process(clk)
        variable x : std_ulogic_vector(0 downto 0);
        variable y : std_ulogic_vector(0 downto 0);
        variable w : std_ulogic_vector(0 downto 0);
    begin
        if rising_edge(clk) then
            -- Do consistency checks only on the clock edge
            assert multihit = '0';

            assert not ((e_in.valid or e_in.interrupt) = '1' and e_in.instr_tag.valid = '0') severity failure;
            assert not ((l_in.valid or l_in.interrupt) = '1' and l_in.instr_tag.valid = '0') severity failure;
            assert not ((fp_in.valid or fp_in.interrupt) = '1' and fp_in.instr_tag.valid = '0') severity failure;

            if complete_out.valid = '1' then
                report "completed tag " & integer'image(complete_out.tag);
            end if;
            if e_out.interrupt = '1' then
                report "interrupt at tag " & integer'image(e_out.itag);
            end if;
            if rst = '1' or flush_out = '1' then
                complete_tag <= 0;
            else
                complete_tag <= next_tag;
            end if;
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
        variable ex_valid, ls_valid, fpu_valid : std_ulogic;
        variable ex_intr, ls_intr, fpu_intr : std_ulogic;
    begin
        w_out <= WritebackToRegisterFileInit;
        c_out <= WritebackToCrFileInit;
        f := WritebackToFetch1Init;

        ex_valid := '0';
        ex_intr := '0';
        ls_valid := '0';
        ls_intr := '0';
        fpu_valid := '0';
        fpu_intr := '0';

        if e_in.instr_tag.tag = complete_tag then
            ex_valid := e_in.valid;
            ex_intr := e_in.interrupt;
            stall_ex <= '0';
        else
            stall_ex <= e_in.valid or e_in.interrupt;
        end if;

        if l_in.instr_tag.tag = complete_tag then
            ls_valid := l_in.valid;
            ls_intr := l_in.interrupt;
        end if;

        if fp_in.instr_tag.tag = complete_tag then
            fpu_valid := fp_in.valid;
            fpu_intr := fp_in.interrupt;
            stall_fpu <= '0';
        else
            stall_fpu <= fp_in.valid or fp_in.interrupt;
        end if;

        complete_out.tag <= complete_tag;
        complete_out.valid <= ex_valid or ls_valid or fpu_valid;
        multihit <= (ex_valid and ls_valid) or (ls_valid and fpu_valid) or
                    (fpu_valid and ex_valid) or (ex_intr and ls_intr) or
                    (ls_intr and fpu_intr) or (fpu_intr and ex_intr);

        events.instr_complete <= ex_valid or ls_valid or fpu_valid;
        events.fp_complete <= fpu_valid;

        intr := ex_intr or ls_intr or fpu_intr;
        e_out.interrupt <= intr;
        e_out.itag <= complete_tag;
        e_out.alt_srr0 <= ex_intr and e_in.alt_srr0;
        if ls_intr = '1' then
            vec := l_in.intr_vec;
            e_out.srr1 <= l_in.srr1;
        elsif fpu_intr = '1' then
            vec := fp_in.intr_vec;
            e_out.srr1 <= fp_in.srr1;
        else
            vec := e_in.intr_vec;
            e_out.srr1 <= e_in.srr1;
        end if;

        if ex_valid = '1' and e_in.write_enable = '1' then
            w_out.write_reg <= e_in.write_reg;
            w_out.write_data <= e_in.write_data;
            w_out.write_enable <= '1';
        end if;

        if ex_valid = '1' and e_in.write_cr_enable = '1' then
            c_out.write_cr_enable <= '1';
            c_out.write_cr_mask <= e_in.write_cr_mask;
            c_out.write_cr_data <= e_in.write_cr_data;
        end if;

        if fpu_valid = '1' and fp_in.write_enable = '1' then
            w_out.write_reg <= fp_in.write_reg;
            w_out.write_data <= fp_in.write_data;
            w_out.write_enable <= '1';
        end if;

        if fpu_valid = '1' and fp_in.write_cr_enable = '1' then
            c_out.write_cr_enable <= '1';
            c_out.write_cr_mask <= fp_in.write_cr_mask;
            c_out.write_cr_data <= fp_in.write_cr_data;
        end if;

        e_out.xerc <= fp_in.xerc;
        e_out.write_xerc <= fpu_valid and fp_in.write_xerc;
            
        if ls_valid = '1' and l_in.write_enable = '1' then
            w_out.write_reg <= l_in.write_reg;
            w_out.write_data <= l_in.write_data;
            w_out.write_enable <= '1';
        end if;

        if ls_valid = '1' and l_in.rc = '1' then
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
        if ex_valid = '1' and e_in.rc = '1' and e_in.write_enable = '1' then
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

        -- Outputs to fetch1
        f.redirect := ex_valid and e_in.redirect;
        f.br_nia := e_in.last_nia;
        f.br_last := ex_valid and e_in.br_last;
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

        if complete_out.valid = '1' then
            next_tag <= (complete_tag + 1) mod TAG_COUNT;
        else
            next_tag <= complete_tag;
        end if;

    end process;
end;
