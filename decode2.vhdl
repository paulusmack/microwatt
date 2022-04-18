library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.decode_types.all;
use work.common.all;
use work.helpers.all;
use work.insn_helpers.all;

entity decode2 is
    generic (
        EX1_BYPASS : boolean := true;
        HAS_FPU : boolean := true;
        -- Non-zero to enable log data collection
        LOG_LENGTH : natural := 0
        );
    port (
        clk   : in std_ulogic;
        rst   : in std_ulogic;

        complete_in : in instr_tag_t;
        busy_in   : in std_ulogic;
        stall_out : out std_ulogic;

        stopped_out : out std_ulogic;

        flush_in: in std_ulogic;

        d_in  : in Decode1ToDecode2Type;

        e_out : out Decode2ToExecute1Type;

        r_in  : in RegisterFileToDecode2Type;
        r_out : out Decode2ToRegisterFileType;

        c_in  : in CrFileToDecode2Type;
        c_out : out Decode2ToCrFileType;

        execute_bypass    : in bypass_data_t;
        execute_cr_bypass : in cr_bypass_data_t;

        -- Access to SPRs from core_debug module
        dbg_spr_req  : in std_ulogic;

        log_out : out std_ulogic_vector(9 downto 0)
	);
end entity decode2;

architecture behaviour of decode2 is
    type reg_type is record
        e : Decode2ToExecute1Type;
        repeat : std_ulogic;
    end record;

    signal r, rin : reg_type;

    signal deferred : std_ulogic;

    type decode_input_reg_t is record
        reg_valid : std_ulogic;
        reg       : gspr_index_t;
        data      : std_ulogic_vector(63 downto 0);
    end record;

    type decode_output_reg_t is record
        reg_valid : std_ulogic;
        reg       : gspr_index_t;
    end record;

    function decode_input_reg_a (t : input_reg_a_t; insn_in : std_ulogic_vector(31 downto 0);
                                 reg_data : std_ulogic_vector(63 downto 0);
                                 instr_addr : std_ulogic_vector(63 downto 0))
        return decode_input_reg_t is
    begin
        if t = RA or (t = RA_OR_ZERO and insn_ra(insn_in) /= "00000") then
            return ('1', gpr_to_gspr(insn_ra(insn_in)), reg_data);
        elsif t = CIA then
            return ('0', (others => '0'), instr_addr);
        elsif HAS_FPU and t = FRA then
            return ('1', fpr_to_gspr(insn_fra(insn_in)), reg_data);
        else
            return ('0', (others => '0'), (others => '0'));
        end if;
    end;

    function decode_input_reg_b (t : input_reg_b_t; insn_in : std_ulogic_vector(31 downto 0);
                                 reg_data : std_ulogic_vector(63 downto 0)) return decode_input_reg_t is
        variable ret : decode_input_reg_t;
    begin
        case t is
            when RB =>
                ret := ('1', gpr_to_gspr(insn_rb(insn_in)), reg_data);
            when FRB =>
                if HAS_FPU then
                    ret := ('1', fpr_to_gspr(insn_frb(insn_in)), reg_data);
                else
                    ret := ('0', (others => '0'), (others => '0'));
                end if;
            when CONST_UI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(unsigned(insn_ui(insn_in)), 64)));
            when CONST_SI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_si(insn_in)), 64)));
            when CONST_SI_HI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_si(insn_in)) & x"0000", 64)));
            when CONST_UI_HI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(unsigned(insn_si(insn_in)) & x"0000", 64)));
            when CONST_LI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_li(insn_in)) & "00", 64)));
            when CONST_BD =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_bd(insn_in)) & "00", 64)));
            when CONST_DS =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_ds(insn_in)) & "00", 64)));
            when CONST_DQ =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_dq(insn_in)) & "0000", 64)));
            when CONST_DXHI4 =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_dx(insn_in)) & x"0004", 64)));
            when CONST_M1 =>
                ret := ('0', (others => '0'), x"FFFFFFFFFFFFFFFF");
            when CONST_SH =>
                ret := ('0', (others => '0'), x"00000000000000" & "00" & insn_in(1) & insn_in(15 downto 11));
            when CONST_SH32 =>
                ret := ('0', (others => '0'), x"00000000000000" & "000" & insn_in(15 downto 11));
            when NONE =>
                ret := ('0', (others => '0'), (others => '0'));
        end case;

        return ret;
    end;

    function decode_input_reg_c (t : input_reg_c_t; insn_in : std_ulogic_vector(31 downto 0);
                                 reg_data : std_ulogic_vector(63 downto 0)) return decode_input_reg_t is
    begin
        case t is
            when RS =>
                return ('1', gpr_to_gspr(insn_rs(insn_in)), reg_data);
            when RCR =>
                return ('1', gpr_to_gspr(insn_rcreg(insn_in)), reg_data);
            when FRS =>
                if HAS_FPU then
                    return ('1', fpr_to_gspr(insn_frt(insn_in)), reg_data);
                else
                    return ('0', (others => '0'), (others => '0'));
                end if;
            when FRC =>
                if HAS_FPU then
                    return ('1', fpr_to_gspr(insn_frc(insn_in)), reg_data);
                else
                    return ('0', (others => '0'), (others => '0'));
                end if;
            when NONE =>
                return ('0', (others => '0'), (others => '0'));
        end case;
    end;

    function decode_output_reg (t : output_reg_a_t; insn_in : std_ulogic_vector(31 downto 0))
        return decode_output_reg_t is
    begin
        case t is
            when RT =>
                return ('1', gpr_to_gspr(insn_rt(insn_in)));
            when RA =>
                return ('1', gpr_to_gspr(insn_ra(insn_in)));
            when FRT =>
                if HAS_FPU then
                    return ('1', fpr_to_gspr(insn_frt(insn_in)));
                else
                    return ('0', "000000");
                end if;
            when NONE =>
                return ('0', "000000");
        end case;
    end;

    function decode_rc (t : rc_t; insn_in : std_ulogic_vector(31 downto 0)) return std_ulogic is
    begin
        case t is
            when RC =>
                return insn_rc(insn_in);
            when ONE =>
                return '1';
            when NONE =>
                return '0';
        end case;
    end;

    -- control signals that are derived from insn_type
    type mux_select_array_t is array(insn_type_t) of std_ulogic_vector(2 downto 0);

    constant result_select : mux_select_array_t := (
        OP_AND      => "001",           -- logical_result
        OP_OR       => "001",
        OP_XOR      => "001",
        OP_PRTY     => "001",
        OP_CMPB     => "001",
        OP_EXTS     => "001",
        OP_BPERM    => "001",
        OP_BCD      => "001",
        OP_MTSPR    => "001",
        OP_RLC      => "010",           -- rotator_result
        OP_RLCL     => "010",
        OP_RLCR     => "010",
        OP_SHL      => "010",
        OP_SHR      => "010",
        OP_EXTSWSLI => "010",
        OP_MUL_L64  => "011",           -- muldiv_result
        OP_MUL_H64  => "011",
        OP_MUL_H32  => "011",
        OP_DIV      => "011",
        OP_DIVE     => "011",
        OP_MOD      => "011",
        OP_CNTZ     => "100",           -- countbits_result
        OP_POPCNT   => "100",
        OP_MFSPR    => "101",           -- spr_result
        OP_ADDG6S   => "111",           -- misc_result
        OP_ISEL     => "111",
        OP_DARN     => "111",
        OP_MFMSR    => "111",
        OP_MFCR     => "111",
        OP_SETB     => "111",
        others      => "000"            -- default to adder_result
        );

    constant subresult_select : mux_select_array_t := (
        OP_MUL_L64 => "000",            -- muldiv_result
        OP_MUL_H64 => "001",
        OP_MUL_H32 => "010",
        OP_DIV     => "011",
        OP_DIVE    => "011",
        OP_MOD     => "011",
        OP_ADDG6S  => "001",            -- misc_result
        OP_ISEL    => "010",
        OP_DARN    => "011",
        OP_MFMSR   => "100",
        OP_MFCR    => "101",
        OP_SETB    => "110",
        OP_CMP     => "000",            -- cr_result
        OP_CMPRB   => "001",
        OP_CMPEQB  => "010",
        OP_CROP    => "011",
        OP_MCRXRX  => "100",
        OP_MTCRF   => "101",
        others     => "000"
        );

    -- issue control signals
    signal control_valid_in : std_ulogic;
    signal control_valid_out : std_ulogic;
    signal control_stall_out : std_ulogic;
    signal control_sgl_pipe : std_logic;

    signal gpr_write_valid : std_ulogic;
    signal gpr_write : gspr_index_t;

    signal gpr_a_read_valid : std_ulogic;
    signal gpr_a_read       : gspr_index_t;
    signal gpr_a_bypass     : std_ulogic;

    signal gpr_b_read_valid : std_ulogic;
    signal gpr_b_read       : gspr_index_t;
    signal gpr_b_bypass     : std_ulogic;

    signal gpr_c_read_valid : std_ulogic;
    signal gpr_c_read       : gspr_index_t;
    signal gpr_c_bypass     : std_ulogic;

    signal cr_read_valid   : std_ulogic;
    signal cr_write_valid  : std_ulogic;
    signal cr_bypass       : std_ulogic;

    signal instr_tag       : instr_tag_t;

begin
    control_0: entity work.control
	generic map (
            EX1_BYPASS => EX1_BYPASS
            )
	port map (
            clk         => clk,
            rst         => rst,

            complete_in => complete_in,
            valid_in    => control_valid_in,
            repeated    => r.repeat,
            busy_in     => busy_in,
            deferred    => deferred,
            flush_in    => flush_in,
            sgl_pipe_in => control_sgl_pipe,
            stop_mark_in => d_in.stop_mark,

            gpr_write_valid_in => gpr_write_valid,
            gpr_write_in       => gpr_write,

            gpr_a_read_valid_in  => gpr_a_read_valid,
            gpr_a_read_in        => gpr_a_read,

            gpr_b_read_valid_in  => gpr_b_read_valid,
            gpr_b_read_in        => gpr_b_read,

            gpr_c_read_valid_in  => gpr_c_read_valid,
            gpr_c_read_in        => gpr_c_read,

            execute_next_tag     => execute_bypass.tag,
            execute_next_cr_tag  => execute_cr_bypass.tag,

            cr_read_in           => cr_read_valid,
            cr_write_in          => cr_write_valid,
            cr_bypass            => cr_bypass,

            valid_out   => control_valid_out,
            stall_out   => control_stall_out,
            stopped_out => stopped_out,

            gpr_bypass_a => gpr_a_bypass,
            gpr_bypass_b => gpr_b_bypass,
            gpr_bypass_c => gpr_c_bypass,

            instr_tag_out => instr_tag
            );

    deferred <= r.e.valid and busy_in;

    decode2_0: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or flush_in = '1' or deferred = '0' then
                if rin.e.valid = '1' then
                    report "execute " & to_hstring(rin.e.nia);
                end if;
                r <= rin;
            elsif r.e.sprs_busy = '0' then
                -- Update debug SPR access signal even when stalled
                -- if the instruction in r.e doesn't read any SPRs.
                r.e.dbg_spr_access <= rin.e.dbg_spr_access;
            end if;
        end if;
    end process;

    c_out.read <= d_in.decode.input_cr;

    decode2_1: process(all)
        variable v : reg_type;
        variable decoded_reg_a : decode_input_reg_t;
        variable decoded_reg_b : decode_input_reg_t;
        variable decoded_reg_c : decode_input_reg_t;
        variable decoded_reg_o : decode_output_reg_t;
        variable length : std_ulogic_vector(3 downto 0);
        variable op : insn_type_t;
        variable sprn : spr_num_t;
        variable decctr : std_ulogic;
        variable sprs_busy : std_ulogic;
    begin
        v := r;

        v.e := Decode2ToExecute1Init;

        sprs_busy := '0';

        --v.e.input_cr := d_in.decode.input_cr;
        v.e.output_cr := d_in.decode.output_cr;

        -- Work out whether XER common bits are set
        sprn := decode_spr_num(d_in.insn);
        v.e.output_xer := d_in.decode.output_carry;
        case d_in.decode.insn_type is
            when OP_ADD | OP_MUL_L64 | OP_DIV | OP_DIVE =>
                -- OE field is valid in OP_ADD/OP_MUL_L64 with major opcode 31 only
                if d_in.insn(31 downto 26) = "011111" and insn_oe(d_in.insn) = '1' then
                    v.e.oe := '1';
                    v.e.output_xer := '1';
                end if;
            when others =>
        end case;

        decoded_reg_a := decode_input_reg_a (d_in.decode.input_reg_a, d_in.insn, r_in.read1_data,
                                             d_in.nia);
        decoded_reg_b := decode_input_reg_b (d_in.decode.input_reg_b, d_in.insn, r_in.read2_data);
        decoded_reg_c := decode_input_reg_c (d_in.decode.input_reg_c, d_in.insn, r_in.read3_data);
        decoded_reg_o := decode_output_reg (d_in.decode.output_reg_a, d_in.insn);

        if d_in.decode.lr = '1' then
            v.e.lr := insn_lk(d_in.insn);
        end if;
        op := d_in.decode.insn_type;

        -- Does this instruction decrement CTR?
        -- bc, bclr, bctar with BO(2) = 0 do, but not bcctr.
        decctr := '0';
        if d_in.insn(23) = '0' and
            (op = OP_BC or
             (op = OP_BCREG and not (d_in.insn(10) = '1' and d_in.insn(6) = '0'))) then
            decctr := '1';
        end if;

        if d_in.decode.repeat /= NONE then
            v.e.repeat := '1';
            v.e.second := r.repeat;
            case d_in.decode.repeat is
                when DRSE =>
                    -- do RS|1,RS for LE; RS,RS|1 for BE
                    if r.repeat = d_in.big_endian then
                        decoded_reg_c.reg(0) := '1';
                    end if;
                when DRTE =>
                    -- do RT|1,RT for LE; RT,RT|1 for BE
                    if r.repeat = d_in.big_endian then
                        decoded_reg_o.reg(0) := '1';
                    end if;
                when DUPD =>
                    -- update-form loads, 2nd instruction writes RA
                    if r.repeat = '1' then
                        decoded_reg_o.reg := decoded_reg_a.reg;
                    end if;
                when others =>
            end case;
        elsif decctr = '1' and (v.e.lr = '1' or op = OP_BCREG) then
            -- Branches that decrement CTR and read or write LR or
            -- read TAR need to be doubled
            v.e.repeat := '1';
            v.e.second := r.repeat;
        end if;

        if decctr = '1' and r.repeat = '0' then
            -- read and write CTR
            v.e.ramspr_rdaddr := RAMSPR_CTR;
            v.e.ramspr_even_wraddr := RAMSPR_CTR;
            v.e.ramspr_wr_sel := "10";
            v.e.ramspr_write_even := '1';
            sprs_busy := '1';
        end if;

        v.e.spr_select := d_in.spr_info;

        case op is
            when OP_MFSPR =>
                v.e.ramspr_rdaddr := d_in.ram_spr.index;
                v.e.ramspr_rd_odd := d_in.ram_spr.isodd;
                v.e.spr_is_ram := d_in.ram_spr.valid;
                sprs_busy := d_in.ram_spr.valid;
            when OP_MTSPR =>
                v.e.ramspr_even_wraddr := d_in.ram_spr.index;
                v.e.ramspr_odd_wraddr := d_in.ram_spr.index;
                v.e.ramspr_wr_sel := "00";
                v.e.ramspr_write_even := d_in.ram_spr.valid and not d_in.ram_spr.isodd;
                v.e.ramspr_write_odd := d_in.ram_spr.valid and d_in.ram_spr.isodd;
                v.e.spr_is_ram := d_in.ram_spr.valid;
            when OP_B | OP_BC | OP_BCREG =>
                if v.e.repeat = '0' or r.repeat = '1' then
                    if op = OP_BCREG then
                        if d_in.insn(10) = '0' then
                            v.e.ramspr_rdaddr := RAMSPR_LR;
                        elsif d_in.insn(6) = '0' then
                            v.e.ramspr_rdaddr := RAMSPR_CTR;
                        else
                            v.e.ramspr_rdaddr := RAMSPR_TAR;
                        end if;
                        sprs_busy := '1';
                    end if;
                    v.e.ramspr_wr_sel := "10";
                    v.e.ramspr_odd_wraddr := RAMSPR_CFAR;
                    -- ramspr_write_odd is not set here because we only
                    -- write CFAR if the branch is taken.
                    if v.e.lr = '1' then
                        v.e.ramspr_wr_sel := "11";
                        v.e.ramspr_even_wraddr := RAMSPR_LR;
                        v.e.ramspr_write_even := '1';
                    end if;
                end if;
            when OP_RFID =>
                v.e.ramspr_rdaddr := RAMSPR_SRR0;
                sprs_busy := '1';
            when OP_SC =>
                -- write next_nia to SRR0
                v.e.ramspr_even_wraddr := RAMSPR_SRR0;
                v.e.ramspr_wr_sel := "11";
                v.e.ramspr_write_even := '1';
            when others =>
        end case;

        r_out.read1_enable <= decoded_reg_a.reg_valid and d_in.valid;
        r_out.read1_reg    <= decoded_reg_a.reg;
        r_out.read2_enable <= decoded_reg_b.reg_valid and d_in.valid;
        r_out.read2_reg    <= decoded_reg_b.reg;
        r_out.read3_enable <= decoded_reg_c.reg_valid and d_in.valid;
        r_out.read3_reg    <= decoded_reg_c.reg;

        case d_in.decode.length is
            when is1B =>
                length := "0001";
            when is2B =>
                length := "0010";
            when is4B =>
                length := "0100";
            when is8B =>
                length := "1000";
            when NONE =>
                length := "0000";
        end case;

        -- execute unit
        v.e.nia := d_in.nia;
        v.e.unit := d_in.decode.unit;
        v.e.fac := d_in.decode.facility;
        v.e.instr_tag := instr_tag;
        v.e.read_reg1 := decoded_reg_a.reg;
        v.e.read_reg2 := decoded_reg_b.reg;
        v.e.write_reg := decoded_reg_o.reg;
        v.e.write_reg_enable := decoded_reg_o.reg_valid;
        v.e.rc := decode_rc(d_in.decode.rc, d_in.insn);
        v.e.invert_a := d_in.decode.invert_a;
        v.e.insn_type := op;
        v.e.invert_out := d_in.decode.invert_out;
        v.e.input_carry := d_in.decode.input_carry;
        v.e.output_carry := d_in.decode.output_carry;
        v.e.is_32bit := d_in.decode.is_32bit;
        v.e.is_signed := d_in.decode.is_signed;
        v.e.insn := d_in.insn;
        v.e.data_len := length;
        v.e.byte_reverse := d_in.decode.byte_reverse;
        v.e.sign_extend := d_in.decode.sign_extend;
        v.e.update := d_in.decode.update;
        v.e.reserve := d_in.decode.reserve;
        v.e.br_pred := d_in.br_pred;
        v.e.result_sel := result_select(op);
        v.e.sub_select := subresult_select(op);

        if op = OP_MFSPR then
            if d_in.ram_spr.valid = '1' then
                v.e.result_sel := "110";    -- ramspr_result
            elsif d_in.spr_info.valid = '0' then
                -- Privileged mfspr to invalid/unimplemented SPR numbers
                -- writes the contents of RT back to RT (i.e. it's a no-op)
                v.e.result_sel := "001";    -- logical_result
            end if;
        end if;

        -- See if any of the operands can get their value via the bypass path.
        case gpr_a_bypass is
            when '1' =>
                v.e.read_data1 := execute_bypass.data;
            when others =>
                v.e.read_data1 := decoded_reg_a.data;
        end case;
        case gpr_b_bypass is
            when '1' =>
                v.e.read_data2 := execute_bypass.data;
            when others =>
                v.e.read_data2 := decoded_reg_b.data;
        end case;
        case gpr_c_bypass is
            when '1' =>
                v.e.read_data3 := execute_bypass.data;
            when others =>
                v.e.read_data3 := decoded_reg_c.data;
        end case;

        v.e.cr := c_in.read_cr_data;
        if cr_bypass = '1' then
            v.e.cr := execute_cr_bypass.data;
        end if;

        -- issue control
        control_valid_in <= d_in.valid;
        control_sgl_pipe <= d_in.decode.sgl_pipe;

        gpr_write_valid <= v.e.write_reg_enable;
        gpr_write <= decoded_reg_o.reg;

        gpr_a_read_valid <= decoded_reg_a.reg_valid;
        gpr_a_read <= decoded_reg_a.reg;

        gpr_b_read_valid <= decoded_reg_b.reg_valid;
        gpr_b_read <= decoded_reg_b.reg;

        gpr_c_read_valid <= decoded_reg_c.reg_valid;
        gpr_c_read <= decoded_reg_c.reg;

        cr_write_valid <= d_in.decode.output_cr or decode_rc(d_in.decode.rc, d_in.insn);
        -- Since ops that write CR only write some of the fields,
        -- any op that writes CR effectively also reads it.
        cr_read_valid <= cr_write_valid or d_in.decode.input_cr;

        v.e.valid := control_valid_out;
        if control_valid_out = '1' then
            v.repeat := v.e.repeat and not r.repeat;
        end if;

        v.e.sprs_busy := sprs_busy and control_valid_out;
        v.e.dbg_spr_access := dbg_spr_req and not v.e.sprs_busy;

        stall_out <= control_stall_out or v.repeat;

        if rst = '1' or flush_in = '1' then
            v.e := Decode2ToExecute1Init;
            v.repeat := '0';
        end if;

        -- Update registers
        rin <= v;

        -- Update outputs
        e_out <= r.e;
    end process;

    d2_log: if LOG_LENGTH > 0 generate
        signal log_data : std_ulogic_vector(9 downto 0);
    begin
        dec2_log : process(clk)
        begin
            if rising_edge(clk) then
                log_data <= r.e.nia(5 downto 2) &
                            r.e.valid &
                            stopped_out &
                            stall_out &
                            gpr_a_bypass &
                            gpr_b_bypass &
                            gpr_c_bypass;
            end if;
        end process;
        log_out <= log_data;
    end generate;

end architecture behaviour;
