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

entity execute1 is
    generic (
        SIM : boolean := false;
        EX1_BYPASS : boolean := true;
        HAS_FPU : boolean := true;
        HAS_SHORT_MULT : boolean := false;
        -- Non-zero to enable log data collection
        LOG_LENGTH : natural := 0
        );
    port (
	clk   : in std_ulogic;
        rst   : in std_ulogic;

	-- asynchronous
	flush_in : in std_ulogic;
	busy_out : out std_ulogic;
        wb_stall : in std_ulogic;

	e_in  : in Decode2ToExecute1Type;
        l_in  : in Loadstore1ToExecute1Type;
        fp_in : in FPUToExecute1Type;

	ext_irq_in : std_ulogic;
        wb_in : in WritebackToExecute1Type;

	-- asynchronous
        l_out : out Execute1ToLoadstore1Type;
        fp_out : out Execute1ToFPUType;

	e_out : out Execute1ToWritebackType;
        bypass_data : out bypass_data_t;
        bypass_cr_data : out cr_bypass_data_t;

        dbg_msr_out : out std_ulogic_vector(63 downto 0);

	icache_inval : out std_ulogic;
	terminate_out : out std_ulogic;

        -- PMU event buses
        wb_events    : in WritebackEventType;
        ls_events    : in Loadstore1EventType;
        dc_events    : in DcacheEventType;
        ic_events    : in IcacheEventType;

        -- Access to SPRs from core_debug module
        dbg_spr_req   : in std_ulogic;
        dbg_spr_ack   : out std_ulogic;
        dbg_spr_addr  : in std_ulogic_vector(7 downto 0);
        dbg_spr_data  : out std_ulogic_vector(63 downto 0);

        -- debug
        sim_dump      : in std_ulogic;
        sim_dump_done : out std_ulogic;

        log_out : out std_ulogic_vector(14 downto 0);
        log_rd_addr : out std_ulogic_vector(31 downto 0);
        log_rd_data : in std_ulogic_vector(63 downto 0);
        log_wr_addr : in std_ulogic_vector(31 downto 0)
	);
end entity execute1;

architecture behaviour of execute1 is
    type side_effect_type is record
        terminate : std_ulogic;
        icache_inval : std_ulogic;
        write_cfar : std_ulogic;
        write_xerlow : std_ulogic;
        write_dec : std_ulogic;
        write_loga : std_ulogic;
        inc_loga : std_ulogic;
        write_pmu_spr : std_ulogic;
        ramspr_write_even : std_ulogic;
        ramspr_write_odd : std_ulogic;
    end record;
    constant side_effect_init : side_effect_type := (others => '0');

    type reg_type is record
	e : Execute1ToWritebackType;
        se : side_effect_type;
        msr : std_ulogic_vector(63 downto 0);
        xerc : xer_common_t;
        busy: std_ulogic;
        fp_exception_next : std_ulogic;
        trace_next : std_ulogic;
        prev_op : insn_type_t;
        br_taken : std_ulogic;
        oe : std_ulogic;
        mul_select : std_ulogic_vector(1 downto 0);
	mul_in_progress : std_ulogic;
        mul_finish : std_ulogic;
        div_in_progress : std_ulogic;
        cntz_in_progress : std_ulogic;
        no_instr_avail : std_ulogic;
        instr_dispatch : std_ulogic;
        ext_interrupt : std_ulogic;
        taken_branch_event : std_ulogic;
        br_mispredict : std_ulogic;
        ramspr_even_wraddr : ramspr_index;
        ramspr_odd_wraddr : ramspr_index;
        pmu_spr_wr_num : std_ulogic_vector(4 downto 0);
    end record;
    constant reg_type_init : reg_type :=
        (e => Execute1ToWritebackInit, se => side_effect_init,
         msr => (others => '0'), xerc => xerc_init, prev_op => OP_ILLEGAL, mul_select => "00",
         ramspr_even_wraddr => 0, ramspr_odd_wraddr => 0,
         pmu_spr_wr_num => 5x"0",
         others => '0');

    type actions_type is record
	e : Execute1ToWritebackType;
        se : side_effect_type;
        complete : std_ulogic;
        exception : std_ulogic;
        trap : std_ulogic;
        write_msr : std_ulogic;
        new_msr : std_ulogic_vector(63 downto 0);
        write_xerc : std_ulogic;
        take_branch : std_ulogic;
        direct_branch : std_ulogic;
        start_mul : std_ulogic;
        start_div : std_ulogic;
        start_cntz : std_ulogic;
        do_trace : std_ulogic;
        fp_intr : std_ulogic;
    end record;
    constant actions_type_init : actions_type :=
        (e => Execute1ToWritebackInit, se => side_effect_init,
         new_msr => (others => '0'), others => '0');
    signal actions : actions_type;

    type time_regs_t is record
	tb: std_ulogic_vector(63 downto 0);
	dec: std_ulogic_vector(63 downto 0);
    end record;
    constant time_regs_t_init : time_regs_t := (others => (others => '0'));

    type special_regs_t is record
	msr: std_ulogic_vector(63 downto 0);
        xerc: xer_common_t;
        xer_low: std_ulogic_vector(17 downto 0);
        log_addr_spr : std_ulogic_vector(31 downto 0);
    end record;
    constant special_regs_t_init: special_regs_t :=
        (xerc => xerc_init, xer_low => 18x"0", log_addr_spr => 32x"0",
         others => (others => '0'));

    -- Array for storing instruction addresses
    type ciaqueue is array(tag_number_t) of std_ulogic_vector(63 downto 0);
    signal ciaq : ciaqueue;

    signal r, rin : reg_type;

    signal a_in, b_in, c_in : std_ulogic_vector(63 downto 0);
    signal cr_in : std_ulogic_vector(31 downto 0);
    signal xerc_in : xer_common_t;
    signal mshort_p : std_ulogic_vector(31 downto 0) := (others => '0');

    signal valid_in : std_ulogic;
    signal ctrl: special_regs_t := special_regs_t_init;
    signal ctrl_tmp: special_regs_t := special_regs_t_init;
    signal timeregs: time_regs_t := time_regs_t_init;
    signal timeregs_next: time_regs_t;
    signal right_shift, rot_clear_left, rot_clear_right: std_ulogic;
    signal rot_sign_ext: std_ulogic;
    signal rotator_result: std_ulogic_vector(63 downto 0);
    signal rotator_carry: std_ulogic;
    signal logical_result: std_ulogic_vector(63 downto 0);
    signal do_popcnt: std_ulogic;
    signal countbits_result: std_ulogic_vector(63 downto 0);
    signal alu_result: std_ulogic_vector(63 downto 0);
    signal adder_result: std_ulogic_vector(63 downto 0);
    signal misc_result: std_ulogic_vector(63 downto 0);
    signal slow_result: std_ulogic_vector(63 downto 0);
    signal spr_result: std_ulogic_vector(63 downto 0);
    signal alu_sel : std_ulogic_vector(2 downto 0);
    signal result_mux_sel: std_ulogic_vector(2 downto 0);
    signal sub_mux_sel: std_ulogic_vector(2 downto 0);

    signal carry_32 : std_ulogic;
    signal carry_64 : std_ulogic;
    signal overflow_32 : std_ulogic;
    signal overflow_64 : std_ulogic;

    signal trapval : std_ulogic_vector(4 downto 0);

    signal write_cr_mask : std_ulogic_vector(7 downto 0);
    signal write_cr_data : std_ulogic_vector(31 downto 0);

    -- multiply signals
    signal x_to_multiply: MultiplyInputType;
    signal multiply_to_x: MultiplyOutputType;

    -- divider signals
    signal x_to_divider: Execute1ToDividerType;
    signal divider_to_x: DividerToExecute1Type;

    -- random number generator signals
    signal random_raw  : std_ulogic_vector(63 downto 0);
    signal random_cond : std_ulogic_vector(63 downto 0);
    signal random_err  : std_ulogic;

    -- PMU signals
    signal x_to_pmu : Execute1ToPMUType;
    signal pmu_to_x : PMUToExecute1Type;

    -- signals for logging
    signal exception_log : std_ulogic;
    signal irq_valid_log : std_ulogic;

    -- SPR-related signals
    type ramspr_half_t is array(ramspr_index) of std_ulogic_vector(63 downto 0);
    signal even_sprs : ramspr_half_t := (others => (others => '0'));
    signal odd_sprs : ramspr_half_t := (others => (others => '0'));
    signal ramspr_even : std_ulogic_vector(63 downto 0);
    signal ramspr_odd : std_ulogic_vector(63 downto 0);
    signal ramspr_result : std_ulogic_vector(63 downto 0);
    signal ramspr_rdaddr : ramspr_index;
    signal ramspr_rd_odd : std_ulogic;
    signal ramspr_even_wr_addr : ramspr_index;
    signal ramspr_even_wr_data : std_ulogic_vector(63 downto 0);
    signal ramspr_even_wr_enab : std_ulogic;
    signal ramspr_odd_wr_addr : ramspr_index;
    signal ramspr_odd_wr_data : std_ulogic_vector(63 downto 0);
    signal ramspr_odd_wr_enab : std_ulogic;
    signal ramspr_dbg_data : std_ulogic_vector(63 downto 0);

    type privilege_level is (USER, SUPER);
    type op_privilege_array is array(insn_type_t) of privilege_level;
    constant op_privilege: op_privilege_array := (
        OP_ATTN => SUPER,
        OP_MFMSR => SUPER,
        OP_MTMSRD => SUPER,
        OP_RFID => SUPER,
        OP_TLBIE => SUPER,
        others => USER
        );

    function instr_is_privileged(op: insn_type_t; insn: std_ulogic_vector(31 downto 0))
        return boolean is
    begin
        if op_privilege(op) = SUPER then
            return true;
        elsif op = OP_MFSPR or op = OP_MTSPR then
            return insn(20) = '1';
        else
            return false;
        end if;
    end;

    procedure set_carry(e: inout Execute1ToWritebackType;
			carry32 : in std_ulogic;
			carry : in std_ulogic) is
    begin
	e.xerc.ca32 := carry32;
	e.xerc.ca := carry;
    end;

    procedure set_ov(e: inout Execute1ToWritebackType;
		     ov   : in std_ulogic;
		     ov32 : in std_ulogic) is
    begin
	e.xerc.ov32 := ov32;
	e.xerc.ov := ov;
	if ov = '1' then
	    e.xerc.so := '1';
	end if;
    end;

    function calc_ov(msb_a : std_ulogic; msb_b: std_ulogic;
		     ca: std_ulogic; msb_r: std_ulogic) return std_ulogic is
    begin
	return (ca xor msb_r) and not (msb_a xor msb_b);
    end;

    function decode_input_carry(ic : carry_in_t;
				xerc : xer_common_t) return std_ulogic is
    begin
	case ic is
	when ZERO =>
	    return '0';
	when CA =>
	    return xerc.ca;
        when OV =>
            return xerc.ov;
	when ONE =>
	    return '1';
	end case;
    end;

    function msr_copy(msr: std_ulogic_vector(63 downto 0))
	return std_ulogic_vector is
	variable msr_out: std_ulogic_vector(63 downto 0);
    begin
	-- ISA says this:
	--  Defined MSR bits are classified as either full func-
	--  tion or partial function. Full function MSR bits are
	--  saved in SRR1 or HSRR1 when an interrupt other
	--  than a System Call Vectored interrupt occurs and
	--  restored by rfscv, rfid, or hrfid, while partial func-
	--  tion MSR bits are not saved or restored.
	--  Full function MSR bits lie in the range 0:32, 37:41, and
	--  48:63, and partial function MSR bits lie in the range
	--  33:36 and 42:47. (Note this is IBM bit numbering).
	msr_out := (others => '0');
	msr_out(63 downto 31) := msr(63 downto 31);
	msr_out(26 downto 22) := msr(26 downto 22);
	msr_out(15 downto 0)  := msr(15 downto 0);
	return msr_out;
    end;

    function intr_srr1(msr: std_ulogic_vector; flags: std_ulogic_vector)
        return std_ulogic_vector is
        variable srr1: std_ulogic_vector(63 downto 0);
    begin
        srr1(63 downto 31) := msr(63 downto 31);
        srr1(30 downto 27) := flags(14 downto 11);
        srr1(26 downto 22) := msr(26 downto 22);
        srr1(21 downto 16) := flags(5 downto 0);
        srr1(15 downto  0) := msr(15 downto 0);
        return srr1;
    end;

    -- Work out whether a signed value fits into n bits,
    -- that is, see if it is in the range -2^(n-1) .. 2^(n-1) - 1
    function fits_in_n_bits(val: std_ulogic_vector; n: integer) return boolean is
        variable x, xp1: std_ulogic_vector(val'left downto val'right);
    begin
        x := val;
        if val(val'left) = '0' then
            x := not val;
        end if;
        xp1 := bit_reverse(std_ulogic_vector(unsigned(bit_reverse(x)) + 1));
        x := x and not xp1;
        -- For positive inputs, x has ones at the positions
        -- to the left of the leftmost 1 bit in val.
        -- For negative inputs, x has ones to the left of
        -- the leftmost 0 bit in val.
        return x(n - 1) = '1';
    end;

    function assemble_xer(xerc: xer_common_t; xer_low: std_ulogic_vector)
        return std_ulogic_vector is
    begin
        return 32x"0" & xerc.so & xerc.ov & xerc.ca & "000000000" &
            xerc.ov32 & xerc.ca32 & xer_low(17 downto 0);
    end;

    -- Tell vivado to keep the hierarchy for the random module so that the
    -- net names in the xdc file match.
    attribute keep_hierarchy : string;
    attribute keep_hierarchy of random_0 : label is "yes";

begin

    rotator_0: entity work.rotator
	port map (
	    rs => c_in,
	    ra => a_in,
	    shift => b_in(6 downto 0),
	    insn => e_in.insn,
	    is_32bit => e_in.is_32bit,
	    right_shift => right_shift,
	    arith => e_in.is_signed,
	    clear_left => rot_clear_left,
	    clear_right => rot_clear_right,
            sign_ext_rs => rot_sign_ext,
	    result => rotator_result,
	    carry_out => rotator_carry
	    );

    logical_0: entity work.logical
	port map (
	    rs => c_in,
	    rb => b_in,
	    op => e_in.insn_type,
	    invert_in => e_in.invert_a,
	    invert_out => e_in.invert_out,
	    result => logical_result,
            datalen => e_in.data_len
	    );

    countbits_0: entity work.bit_counter
	port map (
            clk => clk,
	    rs => c_in,
	    count_right => e_in.insn(10),
	    is_32bit => e_in.is_32bit,
            do_popcnt => do_popcnt,
            datalen => e_in.data_len,
	    result => countbits_result
	    );

    multiply_0: entity work.multiply
        port map (
            clk => clk,
            m_in => x_to_multiply,
            m_out => multiply_to_x
            );

    divider_0: entity work.divider
        port map (
            clk => clk,
            rst => rst,
            d_in => x_to_divider,
            d_out => divider_to_x
            );

    random_0: entity work.random
        port map (
            clk => clk,
            data => random_cond,
            raw => random_raw,
            err => random_err
            );

    pmu_0: entity work.pmu
        port map (
            clk => clk,
            rst => rst,
            p_in => x_to_pmu,
            p_out => pmu_to_x
            );

    short_mult_0: if HAS_SHORT_MULT generate
    begin
        short_mult: entity work.short_multiply
        port map (
            clk => clk,
            a_in => a_in(15 downto 0),
            b_in => b_in(15 downto 0),
            m_out => mshort_p
            );
    end generate;

    log_rd_addr <= ctrl.log_addr_spr;

    a_in <= e_in.read_data1;
    b_in <= e_in.read_data2;
    c_in <= e_in.read_data3;
    cr_in <= e_in.cr;

    x_to_pmu.occur <= (instr_complete => wb_events.instr_complete,
                       fp_complete => wb_events.fp_complete,
                       ld_complete => ls_events.load_complete,
                       st_complete => ls_events.store_complete,
                       itlb_miss => ls_events.itlb_miss,
                       dc_load_miss => dc_events.load_miss,
                       dc_ld_miss_resolved => dc_events.dcache_refill,
                       dc_store_miss => dc_events.store_miss,
                       dtlb_miss => dc_events.dtlb_miss,
                       dtlb_miss_resolved => dc_events.dtlb_miss_resolved,
                       icache_miss => ic_events.icache_miss,
                       itlb_miss_resolved => ic_events.itlb_miss_resolved,
                       no_instr_avail => r.no_instr_avail,
                       dispatch => r.instr_dispatch,
                       ext_interrupt => r.ext_interrupt,
                       br_taken_complete => r.taken_branch_event,
                       br_mispredict => r.br_mispredict,
                       others => '0');
    x_to_pmu.nia <= e_in.nia;
    x_to_pmu.addr <= (others => '0');
    x_to_pmu.addr_v <= '0';
    x_to_pmu.spr_rad <= e_in.insn(20 downto 16);
    x_to_pmu.spr_wad <= r.pmu_spr_wr_num;
    x_to_pmu.spr_val <= r.e.write_data;
    x_to_pmu.run <= '1';

    -- XER is now maintained entirely in this module
    xerc_in <= r.xerc;

    with e_in.unit select busy_out <=
        l_in.busy or fp_in.busy or r.busy or wb_stall when LDST,
        fp_in.busy or r.busy or wb_stall when FPU,
        r.busy or wb_stall when others;

    valid_in <= e_in.valid and not busy_out and not flush_in;

    terminate_out <= r.se.terminate and not wb_stall;

    -- SPRs stored in two small RAM arrays (two so that we can read and write
    -- two SPRs in each cycle).

    ramspr_read: process(all)
        variable cia : std_ulogic_vector(63 downto 0);
        variable even_rd_data, odd_rd_data : std_ulogic_vector(63 downto 0);
        variable even_wr_addr, odd_wr_addr : ramspr_index;
        variable even_wr_enab, odd_wr_enab : std_ulogic;
        variable even_wr_data, odd_wr_data : std_ulogic_vector(63 downto 0);
        variable odd_data_dec : std_ulogic_vector(63 downto 0);
        variable doit : std_ulogic;
    begin
        -- Read address mux and async RAM reading
        if e_in.dbg_spr_access = '1' then
            ramspr_rdaddr <= to_integer(unsigned(dbg_spr_addr(3 downto 1)));
        else
            ramspr_rdaddr <= e_in.ramspr_rdaddr;
        end if;
        even_rd_data := even_sprs(ramspr_rdaddr);
        odd_rd_data := odd_sprs(ramspr_rdaddr);
        if dbg_spr_addr(0) = '0' then
            ramspr_dbg_data <= even_rd_data;
        else
            ramspr_dbg_data <= odd_rd_data;
        end if;

        -- completed instruction address
        cia := ciaq(wb_in.itag);

        -- Write address and data muxes
        doit := r.e.valid and not wb_stall;
        even_wr_enab := (r.se.ramspr_write_even and doit) or wb_in.interrupt;
        odd_wr_enab  := (r.se.ramspr_write_odd and doit) or wb_in.interrupt;
        if wb_in.interrupt = '1' then
            even_wr_addr := RAMSPR_SRR0;
            odd_wr_addr := RAMSPR_SRR1;
        else
            even_wr_addr := r.ramspr_even_wraddr;
            odd_wr_addr  := r.ramspr_odd_wraddr;
        end if;
        if (wb_in.interrupt = '1' and wb_in.alt_srr0 = '0') or r.se.write_cfar = '1' then
            even_wr_data := cia;
        else
            even_wr_data := r.e.write_data;
        end if;
        if wb_in.interrupt = '1' then
            odd_wr_data := intr_srr1(ctrl.msr, wb_in.srr1);
        else
            odd_wr_data := r.e.write_data;
        end if;
        ramspr_even_wr_addr <= even_wr_addr;
        ramspr_even_wr_data <= even_wr_data;
        ramspr_even_wr_enab <= even_wr_enab;
        ramspr_odd_wr_addr <= odd_wr_addr;
        ramspr_odd_wr_data <= odd_wr_data;
        ramspr_odd_wr_enab <= odd_wr_enab;

        -- SPR RAM read with write data bypass
        -- We assume no instruction executes in the cycle immediately following
        -- an interrupt, so we don't need to bypass interrupt data
        if r.se.ramspr_write_even = '1' and e_in.ramspr_rdaddr = r.ramspr_even_wraddr then
            ramspr_even <= even_wr_data;
        else
            ramspr_even <= even_rd_data;
        end if;
        if r.se.ramspr_write_odd = '1' and e_in.ramspr_rdaddr = r.ramspr_odd_wraddr then
            ramspr_odd <= r.e.write_data;
        else
            ramspr_odd <= odd_rd_data;
        end if;
        if e_in.ramspr_rd_odd = '0' then
            ramspr_result <= ramspr_even;
        elsif e_in.dec_ctr = '0' then
            ramspr_result <= ramspr_odd;
        else
            ramspr_result <= std_ulogic_vector(unsigned(ramspr_odd) - 1);
        end if;
    end process;

    ramspr_write: process(clk)
    begin
        if rising_edge(clk) then
            if ramspr_even_wr_enab = '1' then
                even_sprs(ramspr_even_wr_addr) <= ramspr_even_wr_data;
                report "writing even spr " & integer'image(ramspr_even_wr_addr) & " data=" &
                    to_hstring(ramspr_even_wr_data);
            end if;
            if ramspr_odd_wr_enab = '1' then
                odd_sprs(ramspr_odd_wr_addr) <= ramspr_odd_wr_data;
                report "writing odd spr " & integer'image(ramspr_odd_wr_addr) & " data=" &
                    to_hstring(ramspr_odd_wr_data);
            end if;
        end if;
    end process;

    -- SPR read mux
    with e_in.spr_select.sel select spr_result <=
        timeregs.tb when SPRSEL_TB,
        32x"0" & timeregs.tb(63 downto 32) when SPRSEL_TBU,
        timeregs.dec when SPRSEL_DEC,
        32x"0" & PVR_MICROWATT when SPRSEL_PVR,
        log_wr_addr & ctrl.log_addr_spr when SPRSEL_LOGA,
        log_rd_data when SPRSEL_LOGD,
        pmu_to_x.spr_val when SPRSEL_PMU,
        assemble_xer(xerc_in, ctrl.xer_low) when others;

    -- Result mux
    alu_sel <= e_in.result_sel when r.busy = '0' else "011";
    with alu_sel select alu_result <=
        adder_result       when "000",
        logical_result     when "001",
        rotator_result     when "010",
        slow_result        when "011",
        64x"0"             when "100",
        spr_result         when "101",
        ramspr_result      when "110",
        misc_result        when others;

    execute1_0: process(clk)
    begin
	if rising_edge(clk) then
            if rst = '1' then
                r <= reg_type_init;
                timeregs.tb <= (others => '0');
                timeregs.dec <= (others => '0');
                ctrl <= special_regs_t_init;
                ctrl.msr <= (MSR_SF => '1', MSR_LE => '1', others => '0');
                r.msr <= (MSR_SF => '1', MSR_LE => '1', others => '0');
            else
                r <= rin;
                if ctrl.msr /= ctrl_tmp.msr then
                    report "committing MSR " & to_hstring(ctrl_tmp.msr);
                end if;
                ctrl <= ctrl_tmp;
                timeregs <= timeregs_next;
                if valid_in = '1' then
                    report "execute " & to_hstring(e_in.nia) & " op=" & insn_type_t'image(e_in.insn_type) &
                        " wr=" & to_hstring(rin.e.write_reg) & " we=" & std_ulogic'image(rin.e.write_enable) &
                        " tag=" & integer'image(rin.e.instr_tag.tag) & std_ulogic'image(rin.e.instr_tag.valid) &
                        " wd=" & to_hstring(rin.e.write_data);
                end if;
                if e_in.valid = '1' then
                    ciaq(e_in.instr_tag.tag) <= e_in.nia;
                end if;
            end if;
	end if;
    end process;

    ex_dbg_spr: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '0' and dbg_spr_req = '1' then
                if e_in.dbg_spr_access = '1' and (e_in.valid and e_in.sprs_busy) = '0' and
                    dbg_spr_ack = '0' then
                    if dbg_spr_addr(7) = '1' then
                        dbg_spr_data <= ramspr_dbg_data;
                    else
                        dbg_spr_data <= assemble_xer(r.xerc, ctrl.xer_low);
                    end if;
                    dbg_spr_ack <= '1';
                end if;
            else
                dbg_spr_ack <= '0';
            end if;
        end if;
    end process;

    -- Data path for integer instructions
    execute1_dp: process(all)
	variable a_inv : std_ulogic_vector(63 downto 0);
	variable sum_with_carry : std_ulogic_vector(64 downto 0);
        variable sign1, sign2 : std_ulogic;
        variable abs1, abs2 : signed(63 downto 0);
        variable addend : std_ulogic_vector(127 downto 0);
	variable addg6s : std_ulogic_vector(63 downto 0);
	variable crbit : integer range 0 to 31;
	variable isel_result : std_ulogic_vector(63 downto 0);
	variable darn : std_ulogic_vector(63 downto 0);
	variable setb_result : std_ulogic_vector(63 downto 0);
	variable mfcr_result : std_ulogic_vector(63 downto 0);
	variable lo, hi : integer;
	variable l : std_ulogic;
        variable zerohi, zerolo : std_ulogic;
        variable msb_a, msb_b : std_ulogic;
        variable a_lt : std_ulogic;
        variable a_lt_lo : std_ulogic;
        variable a_lt_hi : std_ulogic;
	variable newcrf : std_ulogic_vector(3 downto 0);
	variable bf, bfa : std_ulogic_vector(2 downto 0);
	variable crnum : crnum_t;
	variable scrnum : crnum_t;
        variable cr_operands : std_ulogic_vector(1 downto 0);
	variable crresult : std_ulogic;
	variable bt, ba, bb : std_ulogic_vector(4 downto 0);
        variable btnum : integer range 0 to 3;
	variable banum, bbnum : integer range 0 to 31;
        variable j : integer;
    begin
        -- Main adder
        if e_in.invert_a = '0' then
            a_inv := a_in;
        else
            a_inv := not a_in;
        end if;
        sum_with_carry := ppc_adde(a_inv, b_in,
                                   decode_input_carry(e_in.input_carry, xerc_in));
        adder_result <= sum_with_carry(63 downto 0);
        carry_32 <= sum_with_carry(32) xor a_inv(32) xor b_in(32);
        carry_64 <= sum_with_carry(64);
        overflow_32 <= calc_ov(a_inv(31), b_in(31), carry_32, sum_with_carry(31));
        overflow_64 <= calc_ov(a_inv(63), b_in(63), carry_64, sum_with_carry(63));

        -- signals to multiply and divide units
        sign1 := '0';
        sign2 := '0';
        if e_in.is_signed = '1' then
            if e_in.is_32bit = '1' then
                sign1 := a_in(31);
                sign2 := b_in(31);
            else
                sign1 := a_in(63);
                sign2 := b_in(63);
            end if;
        end if;
        -- take absolute values
        if sign1 = '0' then
            abs1 := signed(a_in);
        else
            abs1 := - signed(a_in);
        end if;
        if sign2 = '0' then
            abs2 := signed(b_in);
        else
            abs2 := - signed(b_in);
        end if;

        -- Interface to multiply and divide units
        x_to_divider.flush <= flush_in;
        x_to_divider.is_signed <= e_in.is_signed;
	x_to_divider.is_32bit <= e_in.is_32bit;
        x_to_divider.is_extended <= '0';
        x_to_divider.is_modulus <= '0';
        if e_in.insn_type = OP_MOD then
            x_to_divider.is_modulus <= '1';
        end if;

        addend := (others => '0');
        if e_in.insn(26) = '0' then
            -- integer multiply-add, major op 4 (if it is a multiply)
            addend(63 downto 0) := c_in;
            if e_in.is_signed = '1' then
                addend(127 downto 64) := (others => c_in(63));
            end if;
        end if;
        if (sign1 xor sign2) = '1' then
            addend := not addend;
        end if;

	x_to_multiply.is_32bit <= e_in.is_32bit;
        x_to_multiply.not_result <= sign1 xor sign2;
        x_to_multiply.addend <= addend;
        x_to_divider.neg_result <= sign1 xor (sign2 and not x_to_divider.is_modulus);
        if e_in.is_32bit = '0' then
            -- 64-bit forms
            x_to_multiply.data1 <= std_ulogic_vector(abs1);
            x_to_multiply.data2 <= std_ulogic_vector(abs2);
            if e_in.insn_type = OP_DIVE then
                x_to_divider.is_extended <= '1';
            end if;
            x_to_divider.dividend <= std_ulogic_vector(abs1);
            x_to_divider.divisor <= std_ulogic_vector(abs2);
        else
            -- 32-bit forms
            x_to_multiply.data1 <= x"00000000" & std_ulogic_vector(abs1(31 downto 0));
            x_to_multiply.data2 <= x"00000000" & std_ulogic_vector(abs2(31 downto 0));
            x_to_divider.is_extended <= '0';
            if e_in.insn_type = OP_DIVE then   -- extended forms
                x_to_divider.dividend <= std_ulogic_vector(abs1(31 downto 0)) & x"00000000";
            else
                x_to_divider.dividend <= x"00000000" & std_ulogic_vector(abs1(31 downto 0));
            end if;
            x_to_divider.divisor <= x"00000000" & std_ulogic_vector(abs2(31 downto 0));
        end if;

        if HAS_SHORT_MULT and r.busy = '0' then
            slow_result <= std_ulogic_vector(resize(signed(mshort_p), 64));
        elsif r.mul_in_progress = '1' then
            case r.mul_select is
            when "10" =>
                slow_result <= multiply_to_x.result(127 downto 64);
            when "11" =>
                slow_result <= multiply_to_x.result(63 downto 32) &
                                 multiply_to_x.result(63 downto 32);
            when others =>
                slow_result <= multiply_to_x.result(63 downto 0);
            end case;
        elsif r.cntz_in_progress = '1' then
            slow_result <= countbits_result;
        else
            slow_result <= divider_to_x.write_reg_data;
        end if;

        -- Compute misc_result
        case e_in.sub_select is
            when "000" =>
                misc_result <= (others => '0');
            when "001" =>
                -- addg6s
                addg6s := (others => '0');
                for i in 0 to 14 loop
                    lo := i * 4;
                    hi := (i + 1) * 4;
                    if (a_in(hi) xor b_in(hi) xor sum_with_carry(hi)) = '0' then
                        addg6s(lo + 3 downto lo) := "0110";
                    end if;
                end loop;
                if sum_with_carry(64) = '0' then
                    addg6s(63 downto 60) := "0110";
                end if;
                misc_result <= addg6s;
            when "010" =>
                -- isel
		crbit := to_integer(unsigned(insn_bc(e_in.insn)));
		if cr_in(31-crbit) = '1' then
		    isel_result := a_in;
		else
		    isel_result := b_in;
		end if;
                misc_result <= isel_result;
            when "011" =>
                -- darn
                darn := (others => '1');
                if random_err = '0' then
                    case e_in.insn(17 downto 16) is
                        when "00" =>
                            darn := x"00000000" & random_cond(31 downto 0);
                        when "10" =>
                            darn := random_raw;
                        when others =>
                            darn := random_cond;
                    end case;
                end if;
                misc_result <= darn;
            when "100" =>
                -- mfmsr
		misc_result <= r.msr;
            when "101" =>
		if e_in.insn(20) = '0' then
		    -- mfcr
		    mfcr_result := x"00000000" & cr_in;
		else
		    -- mfocrf
		    crnum := fxm_to_num(insn_fxm(e_in.insn));
		    mfcr_result := (others => '0');
		    for i in 0 to 7 loop
			lo := (7-i)*4;
			hi := lo + 3;
			if crnum = i then
			    mfcr_result(hi downto lo) := cr_in(hi downto lo);
			end if;
		    end loop;
		end if;
                misc_result <= mfcr_result;
            when "110" =>
                -- setb
                bfa := insn_bfa(e_in.insn);
                crbit := to_integer(unsigned(bfa)) * 4;
                setb_result := (others => '0');
                if cr_in(31 - crbit) = '1' then
                    setb_result := (others => '1');
                elsif cr_in(30 - crbit) = '1' then
                    setb_result(0) := '1';
                end if;
                misc_result <= setb_result;
            when others =>
                misc_result <= (others => '0');
        end case;

        -- compute comparison results
        -- Note, we have done RB - RA, not RA - RB
        if e_in.insn_type = OP_CMP then
            l := insn_l(e_in.insn);
        else
            l := not e_in.is_32bit;
        end if;
        zerolo := not (or (a_in(31 downto 0) xor b_in(31 downto 0)));
        zerohi := not (or (a_in(63 downto 32) xor b_in(63 downto 32)));
        if zerolo = '1' and (l = '0' or zerohi = '1') then
            -- values are equal
            trapval <= "00100";
        else
            a_lt_lo := '0';
            a_lt_hi := '0';
            if unsigned(a_in(30 downto 0)) < unsigned(b_in(30 downto 0)) then
                a_lt_lo := '1';
            end if;
            if unsigned(a_in(62 downto 31)) < unsigned(b_in(62 downto 31)) then
                a_lt_hi := '1';
            end if;
            if l = '1' then
                -- 64-bit comparison
                msb_a := a_in(63);
                msb_b := b_in(63);
                a_lt := a_lt_hi or (zerohi and (a_in(31) xnor b_in(31)) and a_lt_lo);
            else
                -- 32-bit comparison
                msb_a := a_in(31);
                msb_b := b_in(31);
                a_lt := a_lt_lo;
            end if;
            if msb_a /= msb_b then
                -- Comparison is clear from MSB difference.
                -- for signed, 0 is greater; for unsigned, 1 is greater
                trapval <= msb_a & msb_b & '0' & msb_b & msb_a;
            else
                -- MSBs are equal, so signed and unsigned comparisons give the
                -- same answer.
                trapval <= a_lt & not a_lt & '0' & a_lt & not a_lt;
            end if;
        end if;

        -- CR result mux
        bf := insn_bf(e_in.insn);
        crnum := to_integer(unsigned(bf));
        newcrf := (others => '0');
        case e_in.sub_select is
            when "000" =>
                -- CMP and CMPL instructions
                if e_in.is_signed = '1' then
                    newcrf := trapval(4 downto 2) & xerc_in.so;
                else
                    newcrf := trapval(1 downto 0) & trapval(2) & xerc_in.so;
                end if;
            when "001" =>
                newcrf := ppc_cmprb(a_in, b_in, insn_l(e_in.insn));
            when "010" =>
                newcrf := ppc_cmpeqb(a_in, b_in);
            when "011" =>
                if e_in.insn(1) = '1' then
                    -- CR logical instructions
                    j := (7 - crnum) * 4;
                    newcrf := cr_in(j + 3 downto j);
                    bt := insn_bt(e_in.insn);
                    ba := insn_ba(e_in.insn);
                    bb := insn_bb(e_in.insn);
                    btnum := 3 - to_integer(unsigned(bt(1 downto 0)));
                    banum := 31 - to_integer(unsigned(ba));
                    bbnum := 31 - to_integer(unsigned(bb));
                    -- Bits 6-9 of the instruction word give the truth table
                    -- of the requested logical operation
                    cr_operands := cr_in(banum) & cr_in(bbnum);
                    crresult := e_in.insn(6 + to_integer(unsigned(cr_operands)));
                    for i in 0 to 3 loop
                        if i = btnum then
                            newcrf(i) := crresult;
                        end if;
                    end loop;
                else
                    -- MCRF
                    bfa := insn_bfa(e_in.insn);
                    scrnum := to_integer(unsigned(bfa));
                    j := (7 - scrnum) * 4;
                    newcrf := cr_in(j + 3 downto j);
                end if;
            when "100" =>
                -- MCRXRX
                newcrf := xerc_in.ov & xerc_in.ov32 & xerc_in.ca & xerc_in.ca32;
            when others =>
        end case;
        if e_in.insn_type = OP_MTCRF then
            if e_in.insn(20) = '0' then
                -- mtcrf
                write_cr_mask <= insn_fxm(e_in.insn);
            else
                -- mtocrf: We require one hot priority encoding here
                crnum := fxm_to_num(insn_fxm(e_in.insn));
                write_cr_mask <= num_to_fxm(crnum);
            end if;
        else
            write_cr_mask <= num_to_fxm(crnum);
        end if;
        for i in 0 to 7 loop
            if write_cr_mask(i) = '0' then
                write_cr_data(i*4 + 3 downto i*4) <= cr_in(i*4 + 3 downto i*4);
            elsif e_in.insn_type = OP_MTCRF then
                write_cr_data(i*4 + 3 downto i*4) <= c_in(i*4 + 3 downto i*4);
            else
                write_cr_data(i*4 + 3 downto i*4) <= newcrf;
            end if;
        end loop;

    end process;

    execute_1a: process(all)
        variable v: actions_type;
	variable bo, bi : std_ulogic_vector(4 downto 0);
        variable illegal : std_ulogic;
        variable privileged : std_ulogic;
        variable slow_op : std_ulogic;
        variable srr1 : std_ulogic_vector(63 downto 0);
    begin
        v := actions_type_init;
        v.se := side_effect_init;
        v.e.write_data := alu_result;
        v.e.write_reg := e_in.write_reg;
        v.e.write_enable := e_in.write_reg_enable;
        v.e.rc := e_in.rc;
        v.e.write_cr_data := write_cr_data;
        v.e.write_cr_mask := write_cr_mask;
        v.e.write_cr_enable := e_in.output_cr;
        v.e.xerc := xerc_in;
        v.new_msr := r.msr;
        v.write_xerc := e_in.output_xer;
        v.e.redir_mode := r.msr(MSR_IR) & not r.msr(MSR_PR) &
                          not r.msr(MSR_LE) & not r.msr(MSR_SF);
        v.e.intr_vec := 16#700#;
        v.e.mode_32bit := not r.msr(MSR_SF);
        v.e.instr_tag := e_in.instr_tag;
        v.e.last_nia := e_in.nia;
        v.e.br_offset := 64x"4";
        v.se.ramspr_write_even := e_in.ramspr_write_even;
        v.se.ramspr_write_odd := e_in.ramspr_write_odd;

        -- Note the difference between v.exception and v.trap:
        -- v.exception signals a condition that prevents execution of the
        -- instruction, and hence shouldn't depend on operand data, so as to
        -- avoid timing chains through both data and control paths.
        -- v.trap also means we want to generate an interrupt, but doesn't
        -- cancel instruction execution (hence we need to avoid setting any
        -- side-effect flags or write enables when generating a trap).
        -- With v.trap = 1 we will assert both r.e.valid and r.e.interrupt
        -- to writeback, and it will complete the instruction and take
        -- and interrupt.  It is OK for v.trap to depend on operand data.

        illegal := '0';
        privileged := '0';
        slow_op := '0';

        if r.msr(MSR_PR) = '1' and instr_is_privileged(e_in.insn_type, e_in.insn) then
            privileged := '1';
        end if;

        if (not HAS_FPU and e_in.fac = FPU) or e_in.unit = NONE then
            -- make lfd/stfd/lfs/stfs etc. illegal in no-FPU implementations
            illegal := '1';
        end if;

        v.do_trace := r.msr(MSR_SE);
        case_0: case e_in.insn_type is
            when OP_ILLEGAL =>
                illegal := '1';
            when OP_SC =>
                -- check bit 1 of the instruction is 1 so we know this is sc;
                -- 0 would mean scv, so generate an illegal instruction interrupt
                if e_in.insn(1) = '1' then
                    v.trap := '1';
                    v.e.intr_vec := 16#C00#;
                    v.e.alt_srr0 := '1';
                    if e_in.valid = '1' then
                        report "sc";
                    end if;
                else
                    illegal := '1';
                end if;
            when OP_ATTN =>
                -- check bits 1-10 of the instruction to make sure it's attn
                -- if not then it is illegal
                if e_in.insn(10 downto 1) = "0100000000" and r.msr(MSR_PR) = '0' then
                    v.se.terminate := '1';
                    if e_in.valid = '1' then
                        report "ATTN";
                    end if;
                else
                    illegal := '1';
                end if;
            when OP_NOP | OP_DCBF | OP_DCBST | OP_DCBT | OP_DCBTST | OP_ICBT =>
                -- Do nothing
            when OP_ADD =>
                if e_in.output_carry = '1' then
                    if e_in.input_carry /= OV then
                        set_carry(v.e, carry_32, carry_64);
                    else
                        v.e.xerc.ov := carry_64;
                        v.e.xerc.ov32 := carry_32;
                    end if;
                end if;
                if e_in.oe = '1' then
                    set_ov(v.e, overflow_64, overflow_32);
                end if;
            when OP_CMP =>
            when OP_TRAP =>
                -- trap instructions (tw, twi, td, tdi)
                -- set bit 46 to say trap occurred
                v.e.srr1(47 - 46) := '1';
                if or (trapval and insn_to(e_in.insn)) = '1' then
                    -- generate trap-type program interrupt
                    v.trap := '1';
                    if e_in.valid = '1' then
                        report "trap";
                    end if;
                end if;
            when OP_ADDG6S =>
            when OP_CMPRB =>
            when OP_CMPEQB =>
            when OP_AND | OP_OR | OP_XOR | OP_PRTY | OP_CMPB | OP_EXTS |
                OP_BPERM | OP_BCD =>

            when OP_B =>
                v.take_branch := '1';
                v.direct_branch := '1';
                v.e.br_last := '1';
                v.e.br_taken := '1';
                v.e.br_offset := c_in;
                v.e.abs_br := insn_aa(e_in.insn);
                if e_in.br_pred = '0' then
                    -- should never happen
                    v.e.redirect := '1';
                end if;
                if r.msr(MSR_BE) = '1' then
                    v.do_trace := '1';
                end if;
                v.se.write_cfar := '1';
                v.se.ramspr_write_even := '1';
            when OP_BC =>
                -- If CTR is being decremented, it is in ramspr_odd.
                -- This instruction is doubled if it decrements CTR
                -- and also writes LR.
                bo := insn_bo(e_in.insn);
                bi := insn_bi(e_in.insn);
                if e_in.second = '0' then
                    v.take_branch := ppc_bc_taken(bo, bi, cr_in, ramspr_odd);
                else
                    v.take_branch := r.br_taken;
                end if;
                if v.take_branch = '1' then
                    v.e.br_offset := c_in;
                    v.e.abs_br := insn_aa(e_in.insn);
                end if;
                if e_in.repeat = '0' or e_in.second = '1' then
                    -- Mispredicted branches cause a redirect
                    if v.take_branch /= e_in.br_pred then
                        v.e.redirect := '1';
                    end if;
                    v.e.br_taken := v.take_branch;
                    v.direct_branch := '1';
                    v.e.br_last := '1';
                    if r.msr(MSR_BE) = '1' then
                        v.do_trace := '1';
                    end if;
                    if v.take_branch = '1' then
                        v.se.write_cfar := '1';
                        v.se.ramspr_write_even := '1';
                    end if;
                end if;
            when OP_BCREG =>
                -- If CTR is being decremented, it is in ramspr_odd.
                -- This instruction is doubled if it decrements CTR.
                bo := insn_bo(e_in.insn);
                bi := insn_bi(e_in.insn);
                if e_in.second = '0' then
                    v.take_branch := ppc_bc_taken(bo, bi, cr_in, ramspr_odd);
                else
                    v.take_branch := r.br_taken;
                end if;
                if v.take_branch = '1' then
                    v.e.br_offset := ramspr_result;
                    v.e.abs_br := '1';
                end if;
                if e_in.repeat = '0' or e_in.second = '1' then
                    -- Indirect branches are never predicted taken
                    v.e.redirect := v.take_branch;
                    v.e.br_taken := v.take_branch;
                    if r.msr(MSR_BE) = '1' then
                        v.do_trace := '1';
                    end if;
                    if v.take_branch = '1' then
                        v.se.write_cfar := '1';
                        v.se.ramspr_write_even := '1';
                    end if;
                end if;

            when OP_RFID =>
                srr1 := ramspr_odd;
                v.e.redir_mode := (srr1(MSR_IR) or srr1(MSR_PR)) & not srr1(MSR_PR) &
                                  not srr1(MSR_LE) & not srr1(MSR_SF);
                -- Can't use msr_copy here because the partial function MSR
                -- bits should be left unchanged, not zeroed.
                v.new_msr(63 downto 31) := srr1(63 downto 31);
                v.new_msr(26 downto 22) := srr1(26 downto 22);
                v.new_msr(15 downto 0)  := srr1(15 downto 0);
                if srr1(MSR_PR) = '1' then
                    v.new_msr(MSR_EE) := '1';
                    v.new_msr(MSR_IR) := '1';
                    v.new_msr(MSR_DR) := '1';
                end if;
                v.write_msr := '1';
                v.e.br_offset := ramspr_result;
                v.e.abs_br := '1';
                v.e.redirect := '1';
                v.se.write_cfar := '1';
                v.se.ramspr_write_even := '1';
                if HAS_FPU then
                    v.fp_intr := fp_in.exception and
                                 (srr1(MSR_FE0) or srr1(MSR_FE1));
                end if;
                v.do_trace := '0';

            when OP_CNTZ | OP_POPCNT =>
                slow_op := '1';
                v.start_cntz := '1';
            when OP_ISEL =>
            when OP_CROP =>
            when OP_MCRXRX =>
            when OP_DARN =>
            when OP_MFMSR =>
            when OP_MFSPR =>
                if e_in.spr_is_ram = '1' then
                    if e_in.valid = '1' then
                        report "MFSPR to RAM SPR " & integer'image(decode_spr_num(e_in.insn)) &
                            "=" & to_hstring(ramspr_result);
                    end if;
                elsif e_in.spr_select.valid = '1' then
                    if e_in.valid = '1' then
                        report "MFSPR to SPR " & integer'image(decode_spr_num(e_in.insn)) &
                            "=" & to_hstring(spr_result);
                    end if;
                    case e_in.spr_select.sel is
                        when SPRSEL_LOGD =>
                            v.se.inc_loga := '1';
                        when others =>
                    end case;
                else
                    -- mfspr from unimplemented SPRs should be a nop in
                    -- supervisor mode and a program interrupt for user mode
                    if e_in.valid = '1' then
                        report "MFSPR to SPR " & integer'image(decode_spr_num(e_in.insn)) & " invalid";
                    end if;
                    if r.msr(MSR_PR) = '1' then
                        illegal := '1';
                    end if;
                end if;

            when OP_MFCR =>
            when OP_MTCRF =>
            when OP_MTMSRD =>
                v.write_msr := '1';
                if e_in.insn(16) = '1' then
                    -- just update EE and RI
                    v.new_msr(MSR_EE) := c_in(MSR_EE);
                    v.new_msr(MSR_RI) := c_in(MSR_RI);
                else
                    -- Architecture says to leave out bits 3 (HV), 51 (ME)
                    -- and 63 (LE) (IBM bit numbering)
                    if e_in.is_32bit = '0' then
                        v.new_msr(63 downto 61) := c_in(63 downto 61);
                        v.new_msr(59 downto 32) := c_in(59 downto 32);
                    end if;
                    v.new_msr(31 downto 13) := c_in(31 downto 13);
                    v.new_msr(11 downto 1)  := c_in(11 downto 1);
                    if c_in(MSR_PR) = '1' then
                        v.new_msr(MSR_EE) := '1';
                        v.new_msr(MSR_IR) := '1';
                        v.new_msr(MSR_DR) := '1';
                    end if;
                    if HAS_FPU then
                        v.fp_intr := fp_in.exception and
                                     (c_in(MSR_FE0) or c_in(MSR_FE1));
                    end if;
                end if;
            when OP_MTSPR =>
                if e_in.valid = '1' then
                    report "MTSPR to SPR " & integer'image(decode_spr_num(e_in.insn)) &
                        "=" & to_hstring(c_in);
                end if;
                if e_in.spr_select.valid = '1' then
                    case e_in.spr_select.sel is
                        when SPRSEL_XER =>
                            v.e.xerc.so := c_in(63-32);
                            v.e.xerc.ov := c_in(63-33);
                            v.e.xerc.ca := c_in(63-34);
                            v.e.xerc.ov32 := c_in(63-44);
                            v.e.xerc.ca32 := c_in(63-45);
                            v.write_xerc := '1';
                            v.se.write_xerlow := '1';
                        when SPRSEL_DEC =>
                            v.se.write_dec := '1';
                        when SPRSEL_LOGA =>
                            v.se.write_loga := '1';
                        when SPRSEL_PMU =>
                            v.se.write_pmu_spr := '1';
                        when others =>
                    end case;
                end if;
                if e_in.spr_select.valid = '0' and e_in.spr_is_ram = '0' then
                    -- mtspr to unimplemented SPRs should be a nop in
                    -- supervisor mode and a program interrupt for user mode
                    if r.msr(MSR_PR) = '1' then
                        illegal := '1';
                    end if;
                end if;

            when OP_RLC | OP_RLCL | OP_RLCR | OP_SHL | OP_SHR | OP_EXTSWSLI =>
                if e_in.output_carry = '1' then
                    set_carry(v.e, rotator_carry, rotator_carry);
                end if;
            when OP_SETB =>

            when OP_ISYNC =>
                v.e.redirect := '1';

            when OP_ICBI =>
                v.se.icache_inval := '1';

            when OP_MUL_L64 =>
                if HAS_SHORT_MULT and e_in.insn(26) = '1' and
                    fits_in_n_bits(a_in, 16) and fits_in_n_bits(b_in, 16) then
                    -- Operands fit into 16 bits, so use short multiplier
                    if e_in.oe = '1' then
                        -- Note 16x16 multiply can't overflow, even for mullwo
                        set_ov(v.e, '0', '0');
                    end if;
                else
                    -- Use standard multiplier
                    v.start_mul := '1';
                    slow_op := '1';
                end if;

            when OP_MUL_H64 | OP_MUL_H32 =>
                v.start_mul := '1';
                slow_op := '1';

            when OP_DIV | OP_DIVE | OP_MOD =>
                v.start_div := '1';
                slow_op := '1';

            when OP_FETCH_FAILED =>
                -- Handling an ITLB miss doesn't count as having executed an instruction
                v.do_trace := '0';

            when others =>
                if e_in.valid = '1' and e_in.unit = ALU then
                    report "unhandled insn_type " & insn_type_t'image(e_in.insn_type);
                end if;
        end case;

        if privileged = '1' then
            -- generate a program interrupt
            v.exception := '1';
            -- set bit 45 to indicate privileged instruction type interrupt
            v.e.srr1(47 - 45) := '1';
            if e_in.valid = '1' then
                report "privileged instruction";
            end if;

        elsif illegal = '1' then
            v.exception := '1';
            -- Since we aren't doing Hypervisor emulation assist (0xe40) we
            -- set bit 44 to indicate we have an illegal
            v.e.srr1(47 - 44) := '1';
            if e_in.valid = '1' then
                report "illegal instruction";
            end if;

        elsif HAS_FPU and r.msr(MSR_FP) = '0' and e_in.fac = FPU then
            -- generate a floating-point unavailable interrupt
            v.exception := '1';
            v.e.intr_vec := 16#800#;
            if e_in.valid = '1' then
                report "FP unavailable interrupt";
            end if;
        end if;

        if e_in.unit = ALU then
            v.complete := e_in.valid and not v.exception and not slow_op;
        end if;

        actions <= v;
    end process;

    execute1_1: process(all)
	variable v : reg_type;
	variable overflow : std_ulogic;
        variable lv : Execute1ToLoadstore1Type;
	variable irq_valid : std_ulogic;
	variable exception : std_ulogic;
        variable fv : Execute1ToFPUType;
        variable k : integer;
        variable go : std_ulogic;
    begin
	v := r;
        if flush_in = '1' then
            v.e.valid := '0';
            v.e.interrupt := '0';
            v.se := side_effect_init;
        elsif r.busy = '0' and wb_stall = '0' then
            v.e := actions.e;
            v.se := side_effect_init;
            v.oe := e_in.oe;
            v.mul_select := e_in.sub_select(1 downto 0);
        end if;

        lv := Execute1ToLoadstore1Init;
        fv := Execute1ToFPUInit;

        x_to_multiply.valid <= '0';
        x_to_divider.valid <= '0';
	v.mul_in_progress := '0';
        v.div_in_progress := '0';
        v.cntz_in_progress := '0';
        v.mul_finish := '0';
        v.ext_interrupt := '0';
        v.taken_branch_event := '0';
        v.br_mispredict := '0';
	v.busy := '0';

        x_to_pmu.tbbits(3) <= timeregs.tb(63 - 47);
        x_to_pmu.tbbits(2) <= timeregs.tb(63 - 51);
        x_to_pmu.tbbits(1) <= timeregs.tb(63 - 55);
        x_to_pmu.tbbits(0) <= timeregs.tb(63 - 63);
        x_to_pmu.pmm_msr <= r.msr(MSR_PMM);
        x_to_pmu.pr_msr <= r.msr(MSR_PR);
        v.pmu_spr_wr_num := e_in.insn(20 downto 16);

	-- FIXME: run at 512MHz not core freq
	timeregs_next.tb <= std_ulogic_vector(unsigned(timeregs.tb) + 1);
	timeregs_next.dec <= std_ulogic_vector(unsigned(timeregs.dec) - 1);

        irq_valid := r.msr(MSR_EE) and (pmu_to_x.intr or timeregs.dec(63) or ext_irq_in);

	-- rotator control signals
	right_shift <= '1' when e_in.insn_type = OP_SHR else '0';
	rot_clear_left <= '1' when e_in.insn_type = OP_RLC or e_in.insn_type = OP_RLCL else '0';
	rot_clear_right <= '1' when e_in.insn_type = OP_RLC or e_in.insn_type = OP_RLCR else '0';
        rot_sign_ext <= '1' when e_in.insn_type = OP_EXTSWSLI else '0';

        do_popcnt <= '1' when e_in.insn_type = OP_POPCNT else '0';

        if valid_in = '1' then
            v.prev_op := e_in.insn_type;
        end if;

        -- Determine if there is any interrupt to be taken
        -- before/instead of executing this instruction
        exception := valid_in and actions.exception;
        if valid_in = '1' and e_in.second = '0' then
            if HAS_FPU and r.fp_exception_next = '1' then
                -- This is used for FP-type program interrupts that
                -- become pending due to MSR[FE0,FE1] changing from 00 to non-zero.
                exception := '1';
                v.e.intr_vec := 16#700#;
                v.e.srr1 := (others => '0');
                v.e.srr1(47 - 43) := '1';
                v.e.srr1(47 - 47) := '1';
            elsif r.trace_next = '1' then
                -- Generate a trace interrupt rather than executing the next instruction
                -- or taking any asynchronous interrupt
                exception := '1';
                v.e.intr_vec := 16#d00#;
                v.e.srr1 := (others => '0');
                v.e.srr1(47 - 33) := '1';
                if r.prev_op = OP_LOAD or r.prev_op = OP_ICBI or r.prev_op = OP_ICBT or
                    r.prev_op = OP_DCBT or r.prev_op = OP_DCBST or r.prev_op = OP_DCBF then
                    v.e.srr1(47 - 35) := '1';
                elsif r.prev_op = OP_STORE or r.prev_op = OP_DCBZ or r.prev_op = OP_DCBTST then
                    v.e.srr1(47 - 36) := '1';
                end if;

            elsif irq_valid = '1' then
                -- Don't deliver the interrupt until we have a valid instruction
                -- coming in, so we have a valid NIA to put in SRR0.
                if pmu_to_x.intr = '1' then
                    v.e.intr_vec := 16#f00#;
                    report "IRQ valid: PMU";
                elsif timeregs.dec(63) = '1' then
                    v.e.intr_vec := 16#900#;
                    report "IRQ valid: DEC";
                elsif ext_irq_in = '1' then
                    v.e.intr_vec := 16#500#;
                    report "IRQ valid: External";
                    v.ext_interrupt := '1';
                end if;
                v.e.srr1 := (others => '0');
                exception := '1';

            end if;
        end if;
        if exception = '1' then
            v.e.interrupt := '1';
        end if;

        -- only approximate...
        v.no_instr_avail := not (e_in.valid or l_in.busy or r.busy or fp_in.busy);

        go := valid_in and not exception;
        v.instr_dispatch := go;

	if go = '1' then
            v.msr := actions.new_msr;
            v.e.valid := actions.complete;
            v.trace_next := actions.do_trace;
            v.fp_exception_next := actions.fp_intr;

            v.se := actions.se;

            v.cntz_in_progress := actions.start_cntz;
            x_to_multiply.valid <= actions.start_mul;
            v.mul_in_progress := actions.start_mul;
            x_to_divider.valid <= actions.start_div;
            v.div_in_progress := actions.start_div;

            v.br_taken := actions.take_branch;
            v.taken_branch_event := actions.take_branch;
            v.br_mispredict := v.e.redirect and actions.direct_branch;

            v.ramspr_even_wraddr := e_in.ramspr_even_wraddr;
            v.ramspr_odd_wraddr := e_in.ramspr_odd_wraddr;

            v.busy := actions.start_cntz or actions.start_mul or actions.start_div;
            if actions.write_xerc = '1' then
                v.xerc := actions.e.xerc;
            end if;

            if actions.trap = '1' then
                v.e.interrupt := '1';
            end if;

            -- instruction for other units, i.e. LDST
            if e_in.unit = LDST then
                lv.valid := '1';
            elsif HAS_FPU and e_in.unit = FPU then
                fv.valid := '1';
            end if;
        end if;

        -- The following cases all occur when r.busy = 1 and therefore
        -- valid_in = 0.  Hence they don't happen in the same cycle as any of
        -- the cases above which depend on valid_in = 1.
        if r.cntz_in_progress = '1' and flush_in = '0' then
            -- cnt[lt]z and popcnt* always take two cycles
            v.e.valid := '1';
            v.e.write_data := alu_result;
        end if;
	if r.div_in_progress = '1' and flush_in = '0' then
	    if divider_to_x.valid = '1' then
                v.e.write_data := alu_result;
                overflow := divider_to_x.overflow;
                -- We must test oe because the RC update code in writeback
                -- will use the xerc value to set CR0:SO so we must not clobber
                -- xerc if OE wasn't set.
                if r.oe = '1' then
                    v.e.xerc.ov := overflow;
                    v.e.xerc.ov32 := overflow;
                    if overflow = '1' then
                        v.e.xerc.so := '1';
                    end if;
                    v.xerc := v.e.xerc;
                end if;
                v.e.valid := '1';
	    else
		v.busy := '1';
		v.div_in_progress := '1';
	    end if;
        end if;
	if r.mul_in_progress = '1' and flush_in = '0' then
	    if multiply_to_x.valid = '1' then
                v.e.write_data := alu_result;
                if r.oe = '1' then
                    -- have to wait until next cycle for overflow indication
                    v.mul_finish := '1';
                    v.busy := '1';
                else
                    v.e.valid := '1';
                end if;
	    else
		v.busy := '1';
		v.mul_in_progress := '1';
	    end if;
        end if;
        if r.mul_finish = '1' and flush_in = '0' then
            v.e.xerc.ov := multiply_to_x.overflow;
            v.e.xerc.ov32 := multiply_to_x.overflow;
            if multiply_to_x.overflow = '1' then
                v.e.xerc.so := '1';
            end if;
            v.xerc := v.e.xerc;
            v.e.valid := '1';
	end if;

        bypass_data.tag.valid <= v.e.write_enable and v.e.valid;
        bypass_data.tag.tag <= v.e.instr_tag.tag;
        bypass_data.data <= v.e.write_data;

        bypass_cr_data.tag.valid <= v.e.write_cr_enable and v.e.valid;
        bypass_cr_data.tag.tag <= v.e.instr_tag.tag;
        bypass_cr_data.data <= v.e.write_cr_data;

        if wb_in.interrupt = '1' then
            v.trace_next := '0';
            v.fp_exception_next := '0';
        end if;

        -- Outputs to loadstore1 (async)
        lv.op := e_in.insn_type;
        lv.nia := e_in.nia;
        lv.instr_tag := e_in.instr_tag;
        lv.addr1 := a_in;
        lv.addr2 := b_in;
        lv.data := c_in;
        lv.write_reg := e_in.write_reg;
        lv.length := e_in.data_len;
        lv.byte_reverse := e_in.byte_reverse xnor r.msr(MSR_LE);
        lv.sign_extend := e_in.sign_extend;
        lv.update := e_in.update;
        lv.xerc := xerc_in;
        lv.reserve := e_in.reserve;
        lv.rc := e_in.rc;
        lv.insn := e_in.insn;
        -- decode l*cix and st*cix instructions here
        if e_in.insn(31 downto 26) = "011111" and e_in.insn(10 downto 9) = "11" and
            e_in.insn(5 downto 1) = "10101" then
            lv.ci := '1';
        end if;
        lv.virt_mode := r.msr(MSR_DR);
        lv.priv_mode := not r.msr(MSR_PR);
        lv.mode_32bit := not r.msr(MSR_SF);
        lv.is_32bit := e_in.is_32bit;
        lv.repeat := e_in.repeat;
        lv.second := e_in.second;

        -- Outputs to FPU
        fv.op := e_in.insn_type;
        fv.nia := e_in.nia;
        fv.insn := e_in.insn;
        fv.itag := e_in.instr_tag;
        fv.single := e_in.is_32bit;
        fv.fe_mode := r.msr(MSR_FE0) & r.msr(MSR_FE1);
        fv.fra := a_in;
        fv.frb := b_in;
        fv.frc := c_in;
        fv.frt := e_in.write_reg;
        fv.rc := e_in.rc;
        fv.out_cr := e_in.output_cr;

        -- Update committed state for completed instructions or
        -- reset working state to the last committed state if flushing.
        -- The instruction in r.e is considered completed if wb_stall = 0.

        ctrl_tmp <= ctrl;
        if r.e.valid = '1' and wb_stall = '0' then
            -- instruction in r.e is now completing, commit its effects to ctrl
            ctrl_tmp.msr <= r.msr;
            ctrl_tmp.xerc <= r.xerc;
            if r.se.write_xerlow = '1' then
                ctrl_tmp.xer_low <= r.e.write_data(17 downto 0);
            end if;
            if r.se.write_dec = '1' then
                timeregs_next.dec <= r.e.write_data;
            end if;
            if r.se.write_loga = '1' then
                ctrl_tmp.log_addr_spr <= r.e.write_data(31 downto 0);
            elsif r.se.inc_loga = '1' then
                ctrl_tmp.log_addr_spr <= std_ulogic_vector(unsigned(ctrl.log_addr_spr) + 1);
            end if;
        elsif flush_in = '1' then
            -- instruction in r.e didn't complete and is now being flushed
            v.msr := ctrl.msr;
            v.xerc := ctrl.xerc;
        end if;
        if wb_in.interrupt = '1' then
            -- note: v.msr = ctrl_tmp.msr at this point since flush_in = 1
            v.msr(MSR_EE) := '0';
            v.msr(MSR_PR) := '0';
            v.msr(MSR_SE) := '0';
            v.msr(MSR_BE) := '0';
            v.msr(MSR_FP) := '0';
            v.msr(MSR_FE0) := '0';
            v.msr(MSR_FE1) := '0';
            v.msr(MSR_IR) := '0';
            v.msr(MSR_DR) := '0';
            v.msr(MSR_RI) := '0';
            v.msr(MSR_LE) := '1';
            ctrl_tmp.msr <= v.msr;
        end if;

        if flush_in = '1' then
            v.msr := ctrl_tmp.msr;
        end if;

	-- Update registers
	rin <= v;

	-- update outputs
        l_out <= lv;
	e_out <= r.e;
        fp_out <= fv;

        x_to_pmu.mtspr <= r.se.write_pmu_spr and not wb_stall;
        icache_inval <= r.se.icache_inval and not wb_stall;

        exception_log <= exception;
        irq_valid_log <= irq_valid;
    end process;

    sim_dump_test: if SIM generate
        dump_exregs: process(all)
            variable xer : std_ulogic_vector(63 downto 0);
        begin
            if sim_dump = '1' then
                report "LR " & to_hstring(odd_sprs(RAMSPR_LR));
                report "CTR " & to_hstring(odd_sprs(RAMSPR_CTR));
                xer := assemble_xer(ctrl.xerc, ctrl.xer_low);
                report "XER " & to_hstring(xer);
                sim_dump_done <= '1';
            else
                sim_dump_done <= '0';
            end if;
        end process;
    end generate;

    -- Keep GHDL synthesis happy
    sim_dump_test_synth: if not SIM generate
        sim_dump_done <= '0';
    end generate;

    e1_log: if LOG_LENGTH > 0 generate
        signal log_data : std_ulogic_vector(14 downto 0);
    begin
        ex1_log : process(clk)
        begin
            if rising_edge(clk) then
                log_data <= ctrl.msr(MSR_EE) & ctrl.msr(MSR_PR) &
                            ctrl.msr(MSR_IR) & ctrl.msr(MSR_DR) &
                            exception_log &
                            irq_valid_log &
                            wb_in.interrupt &
                            "000" &
                            r.e.write_enable &
                            r.e.valid &
                            (r.e.redirect or r.e.interrupt) &
                            r.busy &
                            flush_in;
            end if;
        end process;
        log_out <= log_data;
    end generate;
end architecture behaviour;
