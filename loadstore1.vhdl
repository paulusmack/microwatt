library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.decode_types.all;
use work.common.all;
use work.insn_helpers.all;
use work.helpers.all;

-- 2 cycle LSU
-- We calculate the address in the first cycle

entity loadstore1 is
    generic (
        HAS_FPU : boolean := true;
        HAS_VECVSX : boolean := true;
        -- Non-zero to enable log data collection
        LOG_LENGTH : natural := 0
        );
    port (
        clk   : in std_ulogic;
        rst   : in std_ulogic;

        l_in  : in Execute1ToLoadstore1Type;
        e_out : out Loadstore1ToExecute1Type;
        l_out : out Loadstore1ToWritebackType;
        bypass_data : out bypass_data_t;

        d_out : out Loadstore1ToDcacheType;
        d_in  : in DcacheToLoadstore1Type;

        m_out : out Loadstore1ToMmuType;
        m_in  : in MmuToLoadstore1Type;

        dc_stall  : in std_ulogic;

        log_out : out std_ulogic_vector(9 downto 0)
        );
end loadstore1;

-- Note, we don't currently use the stall output from the dcache because
-- we know it can take two requests without stalling when idle, we are
-- its only user, and we know it never stalls when idle.

architecture behave of loadstore1 is

    -- State machine for unaligned loads/stores
    type state_t is (IDLE,              -- ready for instruction
                     MMU_LOOKUP,        -- waiting for MMU to look up translation
                     TLBIE_WAIT,        -- waiting for MMU to finish doing a tlbie
                     FINISH_LFS         -- write back converted SP data for lfs*
                     );

    type byte_index_t is array(0 to 7) of unsigned(2 downto 0);
    subtype byte_trim_t is std_ulogic_vector(1 downto 0);
    type trim_ctl_t is array(0 to 7) of byte_trim_t;

    type request_t is record
        valid        : std_ulogic;
        dc_req       : std_ulogic;
        load         : std_ulogic;
        store        : std_ulogic;
        tlbie        : std_ulogic;
        dcbz         : std_ulogic;
        read_spr     : std_ulogic;
        write_spr    : std_ulogic;
        mmu_op       : std_ulogic;
        instr_fault  : std_ulogic;
        load_zero    : std_ulogic;
        do_update    : std_ulogic;
        noop         : std_ulogic;
        mode_32bit   : std_ulogic;
	addr         : std_ulogic_vector(63 downto 0);
	addr0        : std_ulogic_vector(63 downto 0);
        byte_sel     : std_ulogic_vector(7 downto 0);
        second_bytes : std_ulogic_vector(7 downto 0);
	store_data   : std_ulogic_vector(63 downto 0);
	write_reg    : gspr_index_t;
        write_tag    : value_tag_t;
	length       : std_ulogic_vector(3 downto 0);
        elt_length   : std_ulogic_vector(3 downto 0);
	byte_reverse : std_ulogic;
        brev_mask    : unsigned(2 downto 0);
	sign_extend  : std_ulogic;
        is_vsx       : std_ulogic;
        left_justify : std_ulogic;
	update       : std_ulogic;
	xerc         : xer_common_t;
        reserve      : std_ulogic;
        atomic       : std_ulogic;
        atomic_last  : std_ulogic;
        rc           : std_ulogic;
        write_cr_tag : value_tag_t;
        nc           : std_ulogic;              -- non-cacheable access
        virt_mode    : std_ulogic;
        priv_mode    : std_ulogic;
        load_sp      : std_ulogic;
        sprn         : std_ulogic_vector(9 downto 0);
        is_slbia     : std_ulogic;
        align_intr   : std_ulogic;
        use_splat    : std_ulogic;
        do_splat     : std_ulogic;
        word_splat   : std_ulogic;
        dword_index  : std_ulogic;
        two_dwords   : std_ulogic;
    end record;
    constant request_init : request_t := (valid => '0', dc_req => '0', load => '0', store => '0', tlbie => '0',
                                          dcbz => '0', read_spr => '0', write_spr => '0', mmu_op => '0',
                                          instr_fault => '0', load_zero => '0', do_update => '0', noop => '0',
                                          mode_32bit => '0', addr => (others => '0'), addr0 => (others => '0'),
                                          byte_sel => x"00", second_bytes => x"00",
                                          store_data => (others => '0'), write_reg => x"00", write_tag => value_tag_init,
                                          length => x"0", elt_length => x"0", byte_reverse => '0', brev_mask => "000",
                                          sign_extend => '0', is_vsx => '0', left_justify => '0',
                                          update => '0', write_cr_tag => value_tag_init,
                                          xerc => xerc_init, reserve => '0',
                                          atomic => '0', atomic_last => '0', rc => '0', nc => '0',
                                          virt_mode => '0', priv_mode => '0', load_sp => '0',
                                          sprn => 10x"0", is_slbia => '0', align_intr => '0',
                                          use_splat => '0', do_splat => '0', word_splat => '0',
                                          dword_index => '0', two_dwords => '0');

    type reg_stage1_t is record
        req : request_t;
        issued : std_ulogic;
    end record;

    type reg_stage2_t is record
        req        : request_t;
        byte_index : byte_index_t;
        use_second : std_ulogic_vector(7 downto 0);
    end record;

    type reg_stage3_t is record
        state        : state_t;
        complete     : std_ulogic;
        write_enable : std_ulogic;
	write_reg    : gspr_index_t;
        write_tag    : value_tag_t;
        write_data   : std_ulogic_vector(63 downto 0);
        rc           : std_ulogic;
        write_cr_tag : value_tag_t;
        xerc         : xer_common_t;
        store_done   : std_ulogic;
        load_data    : std_ulogic_vector(63 downto 0);
        splat_data   : std_ulogic_vector(63 downto 0);
        dar          : std_ulogic_vector(63 downto 0);
        dsisr        : std_ulogic_vector(31 downto 0);
        ld_sp_data   : std_ulogic_vector(31 downto 0);
        ld_sp_nz     : std_ulogic;
        ld_sp_lz     : std_ulogic_vector(5 downto 0);
        stage1_en    : std_ulogic;
    end record;

    signal req_in   : request_t;
    signal r1, r1in : reg_stage1_t;
    signal r2, r2in : reg_stage2_t;
    signal r3, r3in : reg_stage3_t;

    signal busy       : std_ulogic;

    signal store_sp_data : std_ulogic_vector(31 downto 0);
    signal load_dp_data  : std_ulogic_vector(63 downto 0);
    signal store_data    : std_ulogic_vector(63 downto 0);

    signal stage1_issue_enable : std_ulogic;
    signal stage1_req          : request_t;
    signal stage1_dcreq        : std_ulogic;
    signal stage1_dreq         : std_ulogic;
    signal stage2_busy_next    : std_ulogic;
    signal stage3_busy_next    : std_ulogic;

    -- Generate byte enables from sizes
    -- With lxvl/lxvll we can get any length from 0 to 8
    function length_to_sel(length : in std_logic_vector(3 downto 0)) return std_ulogic_vector is
        variable sel : std_ulogic_vector(7 downto 0);
    begin
        sel := "00000000";
        for i in 0 to 7 loop
            if i < to_integer(unsigned(length)) then
                sel(i) := '1';
            end if;
        end loop;
        return sel;
    end function length_to_sel;

    -- Calculate byte enables
    -- This returns 16 bits, giving the select signals for two transfers,
    -- to account for unaligned loads or stores
    function xfer_data_sel(size : in std_logic_vector(3 downto 0);
                           address : in std_logic_vector(2 downto 0))
	return std_ulogic_vector is
        variable longsel : std_ulogic_vector(15 downto 0);
    begin
        longsel := "00000000" & length_to_sel(size);
        return std_ulogic_vector(shift_left(unsigned(longsel),
					    to_integer(unsigned(address))));
    end function xfer_data_sel;

    -- 23-bit right shifter for DP -> SP float conversions
    function shifter_23r(frac: std_ulogic_vector(22 downto 0); shift: unsigned(4 downto 0))
        return std_ulogic_vector is
        variable fs1   : std_ulogic_vector(22 downto 0);
        variable fs2   : std_ulogic_vector(22 downto 0);
    begin
        case shift(1 downto 0) is
            when "00" =>
                fs1 := frac;
            when "01" =>
                fs1 := '0' & frac(22 downto 1);
            when "10" =>
                fs1 := "00" & frac(22 downto 2);
            when others =>
                fs1 := "000" & frac(22 downto 3);
        end case;
        case shift(4 downto 2) is
            when "000" =>
                fs2 := fs1;
            when "001" =>
                fs2 := x"0" & fs1(22 downto 4);
            when "010" =>
                fs2 := x"00" & fs1(22 downto 8);
            when "011" =>
                fs2 := x"000" & fs1(22 downto 12);
            when "100" =>
                fs2 := x"0000" & fs1(22 downto 16);
            when others =>
                fs2 := x"00000" & fs1(22 downto 20);
        end case;
        return fs2;
    end;

    -- 23-bit left shifter for SP -> DP float conversions
    function shifter_23l(frac: std_ulogic_vector(22 downto 0); shift: unsigned(4 downto 0))
        return std_ulogic_vector is
        variable fs1   : std_ulogic_vector(22 downto 0);
        variable fs2   : std_ulogic_vector(22 downto 0);
    begin
        case shift(1 downto 0) is
            when "00" =>
                fs1 := frac;
            when "01" =>
                fs1 := frac(21 downto 0) & '0';
            when "10" =>
                fs1 := frac(20 downto 0) & "00";
            when others =>
                fs1 := frac(19 downto 0) & "000";
        end case;
        case shift(4 downto 2) is
            when "000" =>
                fs2 := fs1;
            when "001" =>
                fs2 := fs1(18 downto 0) & x"0" ;
            when "010" =>
                fs2 := fs1(14 downto 0) & x"00";
            when "011" =>
                fs2 := fs1(10 downto 0) & x"000";
            when "100" =>
                fs2 := fs1(6 downto 0) & x"0000";
            when others =>
                fs2 := fs1(2 downto 0) & x"00000";
        end case;
        return fs2;
    end;

begin
    loadstore1_reg: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                r1.req.valid <= '0';
                r2.req.valid <= '0';
                r3.state <= IDLE;
                r3.complete <= '0';
                r3.write_enable <= '0';
                r3.stage1_en <= '1';
                busy <= '0';
            else
                r1 <= r1in;
                r2 <= r2in;
                r3 <= r3in;
                busy <= l_in.valid or r1.req.valid or stage3_busy_next;
            end if;
            stage1_dreq <= stage1_dcreq;
            if d_in.valid = '1' then
                assert r2.req.valid = '1' and r2.req.dc_req = '1' and r3.state = IDLE severity failure;
            end if;
            if d_in.error = '1' then
                assert r2.req.valid = '1' and r2.req.dc_req = '1' and r3.state = IDLE severity failure;
            end if;
            if m_in.done = '1' or m_in.err = '1' then
                assert r2.req.valid = '1' and (r3.state = MMU_LOOKUP or r3.state = TLBIE_WAIT) severity failure;
            end if;
        end if;
    end process;

    ls_fp_conv: if HAS_FPU generate
        -- Convert DP data to SP for stfs
        dp_to_sp: process(all)
            variable exp   : unsigned(10 downto 0);
            variable frac  : std_ulogic_vector(22 downto 0);
            variable shift : unsigned(4 downto 0);
        begin
            store_sp_data(31) <= l_in.data(63);
            store_sp_data(30 downto 0) <= (others => '0');
            exp := unsigned(l_in.data(62 downto 52));
            if exp > 896 then
                store_sp_data(30) <= l_in.data(62);
                store_sp_data(29 downto 0) <= l_in.data(58 downto 29);
            elsif exp >= 874 then
                -- denormalization required
                frac := '1' & l_in.data(51 downto 30);
                shift := 0 - exp(4 downto 0);
                store_sp_data(22 downto 0) <= shifter_23r(frac, shift);
            end if;
        end process;

        -- Convert SP data to DP for lfs
        sp_to_dp: process(all)
            variable exp     : unsigned(7 downto 0);
            variable exp_dp  : unsigned(10 downto 0);
            variable exp_nz  : std_ulogic;
            variable exp_ao  : std_ulogic;
            variable frac    : std_ulogic_vector(22 downto 0);
            variable frac_shift : unsigned(4 downto 0);
        begin
            frac := r3.ld_sp_data(22 downto 0);
            exp := unsigned(r3.ld_sp_data(30 downto 23));
            exp_nz := or (r3.ld_sp_data(30 downto 23));
            exp_ao := and (r3.ld_sp_data(30 downto 23));
            frac_shift := (others => '0');
            if exp_ao = '1' then
                exp_dp := to_unsigned(2047, 11);    -- infinity or NaN
            elsif exp_nz = '1' then
                exp_dp := 896 + resize(exp, 11);    -- finite normalized value
            elsif r3.ld_sp_nz = '0' then
                exp_dp := to_unsigned(0, 11);       -- zero
            else
                -- denormalized SP operand, need to normalize
                exp_dp := 896 - resize(unsigned(r3.ld_sp_lz), 11);
                frac_shift := unsigned(r3.ld_sp_lz(4 downto 0)) + 1;
            end if;
            load_dp_data(63) <= r3.ld_sp_data(31);
            load_dp_data(62 downto 52) <= std_ulogic_vector(exp_dp);
            load_dp_data(51 downto 29) <= shifter_23l(frac, frac_shift);
            load_dp_data(28 downto 0) <= (others => '0');
        end process;
    end generate;

    -- Translate a load/store instruction into the internal request format
    -- XXX this should only depend on l_in, but actually depends on
    -- r1.next_addr as well (in the l_in.second = 1 case).
    loadstore1_in: process(all)
        variable v : request_t;
        variable lsu_sum : std_ulogic_vector(63 downto 0);
        variable brev_lenm1 : unsigned(2 downto 0);
        variable long_sel : std_ulogic_vector(15 downto 0);
        variable addr : std_ulogic_vector(63 downto 0);
        variable sprn : std_ulogic_vector(9 downto 0);
        variable misaligned : std_ulogic;
        variable is_vector : std_ulogic;
        variable is_vsx_len : std_ulogic;
        variable addr_mask : std_ulogic_vector(2 downto 0);
    begin
        v := request_init;
        sprn := std_ulogic_vector(to_unsigned(decode_spr_num(l_in.insn), 10));
        is_vector := '0';
        is_vsx_len := '0';

        v.valid := l_in.valid;
        v.mode_32bit := l_in.mode_32bit;
        v.write_reg := l_in.write_reg;
        v.write_tag := l_in.write_tag;
        v.length := l_in.length;
        v.elt_length := l_in.length;
        v.byte_reverse := l_in.byte_reverse;
        v.sign_extend := l_in.sign_extend;
        v.update := l_in.update;
        v.xerc := l_in.xerc;
        v.reserve := l_in.reserve;
        v.rc := l_in.rc;
        v.write_cr_tag := l_in.write_cr_tag;
        v.nc := l_in.ci;
        v.virt_mode := l_in.virt_mode;
        v.priv_mode := l_in.priv_mode;
        v.sprn := sprn;

        lsu_sum := std_ulogic_vector(unsigned(l_in.addr1) + unsigned(l_in.addr2));

        if HAS_FPU and l_in.is_32bit = '1' then
            v.store_data := x"00000000" & store_sp_data;
        else
            v.store_data := l_in.data;
        end if;

        if HAS_VECVSX and (l_in.op = OP_VRLOAD or l_in.op = OP_VRSTORE) then
            is_vector := '1';
            v.length := "1000";
        end if;
        if HAS_VECVSX and (l_in.op = OP_VSXLDV or l_in.op = OP_VSXST) then
            v.is_vsx := '1';
            v.length := "1000";
        end if;
        if HAS_VECVSX and l_in.op = OP_VSXLDS then
            -- VSX scalar load, set right half of destination to zero
            if l_in.second = '1' then
                v.length := "0000";
            end if;
        end if;
        if HAS_VECVSX and l_in.op = OP_VSXLDSPLT then
            if l_in.length(3) = '0' then
                v.word_splat := '1';
            end if;
            -- for second half set length to 0 to get splat data
            if l_in.second = '1' then
                v.length := "0000";
            else
                v.length := "1000";
            end if;
        end if;

        if HAS_VECVSX and (l_in.op = OP_VSXLDLEN or l_in.op = OP_VSXSTLEN) then
            -- address is RA|0, byte count is top byte of RB
            is_vsx_len := '1';
            addr := l_in.addr1;
            -- left justify if big-endian or lvxll instruction
            if l_in.insn(6) = '1' then
                v.byte_reverse := '1';
            end if;
            v.left_justify := v.byte_reverse;
            if l_in.addr2(63 downto 60) = "0000" then
                -- byte count is less than 16
                if l_in.second = l_in.addr2(59) then
                    -- 1st transfer and count < 8, or 2nd and 8 <= count < 15
                    v.length := '0' & l_in.addr2(58 downto 56);
                elsif l_in.second = '1' and l_in.addr2(59) = '0' then
                    -- 2nd transfer and count < 8
                    v.length := "0000";
                -- else leave length at 8
                end if;
            end if;
        else
            addr := lsu_sum;
            if is_vector = '1' then
                addr(3 downto 0) := "0000";
            end if;
        end if;

        -- Hack to make dcbz clear 128 bytes
        if l_in.op = OP_DCBZ then
            addr(6) := l_in.second;
        elsif l_in.second = '1' then
            if l_in.update = '0' then
                -- for the second half of a 16-byte transfer,
                -- use the previous address plus 8.
                addr := std_ulogic_vector(unsigned(r1.req.addr0(63 downto 3)) + 1) & r1.req.addr0(2 downto 0);
            else
                -- for an update-form load, use the previous address
                -- as the value to write back to RA.
                addr := r1.req.addr0;
            end if;
        end if;
        if l_in.mode_32bit = '1' then
            addr(63 downto 32) := (others => '0');
        end if;
        v.addr := addr;
        v.addr0 := addr;

        -- XXX Temporary hack. Mark the op as non-cachable if the address
        -- is the form 0xc------- for a real-mode access.
        if addr(31 downto 28) = "1100" and l_in.virt_mode = '0' then
            v.nc := '1';
        end if;

        addr_mask := std_ulogic_vector(unsigned(l_in.length(2 downto 0)) - 1);

        -- Do length_to_sel and work out if we are doing 2 dwords
        if is_vector = '0' then
            long_sel := xfer_data_sel(v.length, addr(2 downto 0));
            v.byte_sel := long_sel(7 downto 0);
            v.second_bytes := long_sel(15 downto 8);
            if long_sel(15 downto 8) /= "00000000" then
                v.two_dwords := '1';
            end if;
        elsif is_vector = '1' then
            -- Vector load/store ops get repeated; for byte/half/word
            -- element ops, one of the two has byte_sel = 0x00.
            -- Note that 16-byte transfers have l_in.length = 8.
            if l_in.length(3) = '1' or lsu_sum(3) = l_in.second then
                long_sel := xfer_data_sel(l_in.length, lsu_sum(2 downto 0) and not addr_mask);
                v.byte_sel := long_sel(7 downto 0);
            else
                v.byte_sel := x"00";
            end if;
            v.second_bytes := x"00";
        end if;

        -- check alignment for larx/stcx
        misaligned := or (addr_mask and addr(2 downto 0));
        v.align_intr := l_in.reserve and misaligned;
        if l_in.repeat = '1' and l_in.second = '0' and l_in.update = '0' and addr(3) = '1' then
            -- length is really 16 not 8
            -- Make misaligned lq cause an alignment interrupt in LE mode,
            -- in order to avoid the case with RA = RT + 1 where the second half
            -- faults but the first doesn't (and updates RT+1, destroying RA).
            -- The equivalent BE case doesn't occur because RA = RT is illegal.
            misaligned := '1';
            if l_in.reserve = '1' or (l_in.op = OP_LOAD and l_in.byte_reverse = '0') then
                v.align_intr := '1';
            end if;
        end if;

        v.atomic := not misaligned;
        v.atomic_last := not misaligned and (l_in.second or not l_in.repeat);

        case l_in.op is
            when OP_STORE | OP_VRSTORE | OP_VSXST =>
                v.store := '1';
            when OP_LOAD | OP_VRLOAD | OP_VSXLDV =>
                if l_in.update = '0' or l_in.second = '0' then
                    v.load := '1';
                    if HAS_FPU and l_in.is_32bit = '1' then
                        -- Allow an extra cycle for SP->DP precision conversion
                        v.load_sp := '1';
                    end if;
                else
                    -- write back address to RA
                    v.do_update := '1';
                end if;
            when OP_VSXLDS =>
                if HAS_VECVSX then
                    if v.length /= "0000" then
                        v.load := '1';
                        v.load_sp := l_in.is_32bit;
                    else
                        v.load_zero := '1';
                    end if;
                end if;
            when OP_VSXLDSPLT =>
                if HAS_VECVSX then
                    if l_in.second = '0' then
                        v.load := '1';
                        v.do_splat := '1';
                    else
                        v.use_splat := '1';
                    end if;
                end if;
            when OP_VSXSTLEN =>
                if HAS_VECVSX then
                    if v.length /= "0000" then
                        v.store := '1';
                    else
                        v.noop := '1';
                    end if;
                end if;
            when OP_VSXLDLEN =>
                if HAS_VECVSX then
                    if v.length /= "0000" then
                        v.load := '1';
                    else
                        v.load_zero := '1';
                    end if;
                end if;
            when OP_DCBZ =>
                v.dcbz := '1';
                v.align_intr := v.nc;
            when OP_TLBIE =>
                v.tlbie := '1';
                v.addr := l_in.addr2;    -- address from RB for tlbie
                v.is_slbia := l_in.insn(7);
                v.mmu_op := '1';
            when OP_MFSPR =>
                v.read_spr := '1';
            when OP_MTSPR =>
                v.write_spr := '1';
                v.mmu_op := sprn(9) or sprn(5);
            when OP_FETCH_FAILED =>
                -- send it to the MMU to do the radix walk
                v.instr_fault := '1';
                v.addr := l_in.nia;
                v.mmu_op := '1';
            when others =>
        end case;
        v.dc_req := l_in.valid and (v.load or v.store or v.dcbz) and not v.align_intr;

        -- Work out controls for load and store formatting
        brev_lenm1 := "000";
        if not HAS_VECVSX or v.is_vsx = '0' then
            if v.byte_reverse = '1' then
                if v.left_justify = '1' then
                    brev_lenm1 := "111";
                else
                    brev_lenm1 := unsigned(v.length(2 downto 0)) - 1;
                end if;
            end if;
        else
            -- VSX stores swap elements and possibly byte-swap each element
            if v.byte_reverse = '1' then
                brev_lenm1 := "111";
            else
                brev_lenm1 := not (unsigned(v.elt_length(2 downto 0)) - 1);
            end if;
        end if;
        v.brev_mask := brev_lenm1;

        req_in <= v;
    end process;

    stage1_issue_enable <= r3.stage1_en;

    -- Processing done in the first cycle of a load/store instruction
    loadstore1_1: process(all)
        variable v     : reg_stage1_t;
        variable req   : request_t;
        variable dcreq : std_ulogic;
        variable addr  : std_ulogic_vector(63 downto 0);
    begin
        v := r1;
        dcreq := '0';
        req := req_in;

        -- Note that l_in.valid is gated with busy inside execute1
        if l_in.valid = '1' then
            dcreq := req_in.dc_req;
            v.req := req_in;
            v.issued := dcreq;
        elsif r1.req.valid = '1' then
            if r1.req.dc_req = '1' and r1.issued = '0' then
                req := r1.req;
                v.issued := stage1_issue_enable;
                dcreq := stage1_issue_enable;
            elsif r1.issued = '1' and d_in.error = '1' then
                v.issued := '0';
            elsif stage2_busy_next = '0' then
                -- we can change what's in r1 next cycle because the current thing
                -- in r1 will go into r2
                if r1.req.dc_req = '1' and r1.req.two_dwords = '1' and r1.req.dword_index = '0' then
                    -- construct the second request for a misaligned access
                    v.req.dword_index := '1';
                    v.req.addr := std_ulogic_vector(unsigned(r1.req.addr(63 downto 3)) + 1) & "000";
                    if r1.req.mode_32bit = '1' then
                        v.req.addr(32) := '0';
                    end if;
                    v.req.byte_sel := r1.req.second_bytes;
                    v.issued := stage1_issue_enable;
                    dcreq := stage1_issue_enable and not dcreq;
                    req := v.req;
                else
                    v.req.valid := '0';
                end if;
            end if;
        end if;
        if e_out.exception = '1' then
            v.req.valid := '0';
            dcreq := '0';
        end if;

        stage1_req <= req;
        stage1_dcreq <= dcreq;
        r1in <= v;
    end process;

    -- Processing done in the second cycle of a load/store instruction.
    -- Store data is formatted here and sent to the dcache.
    -- The request in r1 is sent to stage 3 if stage 3 will not be busy next cycle.
    loadstore1_2: process(all)
        variable v : reg_stage2_t;
        variable j : integer;
        variable k : unsigned(2 downto 0);
        variable kk : unsigned(3 downto 0);
        variable idx : unsigned(2 downto 0);
        variable byte_offset : unsigned(2 downto 0);
    begin
        v := r2;

        -- Byte reversing and rotating for stores.
        -- Done in the second cycle (the cycle after l_in.valid = 1).
        byte_offset := unsigned(r1.req.addr0(2 downto 0));
        for i in 0 to 7 loop
            k := (to_unsigned(i, 3) - byte_offset) xor r1.req.brev_mask;
            j := to_integer(k) * 8;
            store_data(i * 8 + 7 downto i * 8) <= r1.req.store_data(j + 7 downto j);
        end loop;

        if stage3_busy_next = '0' and
            (r1.req.valid = '0' or r1.issued = '1' or r1.req.dc_req = '0') then
            v.req := r1.req;
            v.req.store_data := store_data;

            -- Work out load formatter controls for next cycle
            for i in 0 to 7 loop
                idx := to_unsigned(i, 3) xor r1.req.brev_mask;
                if r1.req.word_splat = '1' then
                    idx(2) := '0';
                end if;
                kk := ('0' & idx) + ('0' & byte_offset);
                v.use_second(i) := kk(3);
                v.byte_index(i) := kk(2 downto 0);
            end loop;
        end if;
        stage2_busy_next <= r2.req.valid and stage3_busy_next;

        if e_out.exception = '1' then
            v.req.valid := '0';
        end if;

        r2in <= v;
    end process;

    -- Processing done in the third cycle of a load/store instruction.
    -- At this stage we can do things that have side effects without
    -- fear of the instruction getting flushed.  This is the point at
    -- which requests get sent to the MMU.
    loadstore1_3: process(all)
        variable v             : reg_stage3_t;
        variable j             : integer;
        variable req           : std_ulogic;
        variable mmureq        : std_ulogic;
        variable mmu_mtspr     : std_ulogic;
        variable write_enable  : std_ulogic;
        variable do_update     : std_ulogic;
        variable done          : std_ulogic;
        variable part_done     : std_ulogic;
        variable exception     : std_ulogic;
        variable data_permuted : std_ulogic_vector(63 downto 0);
        variable data_trimmed  : std_ulogic_vector(63 downto 0);
        variable sprval        : std_ulogic_vector(63 downto 0);
        variable negative      : std_ulogic;
        variable dsisr         : std_ulogic_vector(31 downto 0);
        variable itlb_fault    : std_ulogic;
        variable trim_ctl      : trim_ctl_t;
        variable wr_sel        : std_ulogic_vector(1 downto 0);
    begin
        v := r3;

        req := '0';
        mmureq := '0';
        mmu_mtspr := '0';
        done := '0';
        part_done := '0';
        exception := '0';
        dsisr := (others => '0');
        write_enable := '0';
        wr_sel := "11";
        sprval := (others => '0');
        do_update := '0';

        -- load data formatting
        -- shift and byte-reverse data bytes
        for i in 0 to 7 loop
            j := to_integer(r2.byte_index(i)) * 8;
            data_permuted(i * 8 + 7 downto i * 8) := d_in.data(j + 7 downto j);
        end loop;

        -- Work out the sign bit for sign extension.
        -- For unaligned loads crossing two dwords, the sign bit is in the
        -- first dword for big-endian (byte_reverse = 1), or the second dword
        -- for little-endian.
        if r2.req.dword_index = '1' and r2.req.byte_reverse = '1' then
            negative := (r2.req.length(3) and r3.load_data(63)) or
                        (r2.req.length(2) and r3.load_data(31)) or
                        (r2.req.length(1) and r3.load_data(15)) or
                        (r2.req.length(0) and r3.load_data(7));
        else
            negative := (r2.req.length(3) and data_permuted(63)) or
                        (r2.req.length(2) and data_permuted(31)) or
                        (r2.req.length(1) and data_permuted(15)) or
                        (r2.req.length(0) and data_permuted(7));
        end if;

        -- trim and sign-extend
        for i in 0 to 7 loop
            if r2.req.left_justify = '0' then
                if i < to_integer(unsigned(r2.req.length)) then
                    if r2.req.dword_index = '1' then
                        trim_ctl(i) := '1' & not r2.use_second(i);
                    else
                        trim_ctl(i) := "10";
                    end if;
                else
                    trim_ctl(i) := '0' & r2.req.use_splat;
                end if;
            else
                if i >= 8 - to_integer(unsigned(r2.req.length)) then
                    if r2.req.dword_index = '1' then
                        trim_ctl(i) := '1' & not r2.use_second(i);
                    else
                        trim_ctl(i) := "10";
                    end if;
                else
                    trim_ctl(i) := "00";        -- left-justify never sign extends
                end if;
            end if;
        end loop;

        for i in 0 to 7 loop
            case trim_ctl(i) is
                when "11" =>
                    data_trimmed(i * 8 + 7 downto i * 8) := r3.load_data(i * 8 + 7 downto i * 8);
                when "10" =>
                    data_trimmed(i * 8 + 7 downto i * 8) := data_permuted(i * 8 + 7 downto i * 8);
                when "01" =>
                    data_trimmed(i * 8 + 7 downto i * 8) := r3.splat_data(i * 8 + 7 downto i * 8);
                when others =>
                    data_trimmed(i * 8 + 7 downto i * 8) := (others => negative and r2.req.sign_extend);
            end case;
        end loop;

        if HAS_FPU then
            -- Single-precision FP conversion for loads
            v.ld_sp_data := data_trimmed(31 downto 0);
            v.ld_sp_nz := or (data_trimmed(22 downto 0));
            v.ld_sp_lz := count_left_zeroes(data_trimmed(22 downto 0));
        end if;

        if d_in.valid = '1' then
            if r2.req.load = '1' then
                v.load_data := data_permuted;
            end if;
            if r2.req.do_splat = '1' then
                v.splat_data := data_trimmed;
            end if;
        end if;

        if r2.req.valid = '1' then
            if r2.req.read_spr = '1' then
                wr_sel := "00";
                write_enable := '1';
                -- partial decode on SPR number should be adequate given
                -- the restricted set that get sent down this path
                if r2.req.sprn(9) = '0' and r2.req.sprn(5) = '0' then
                    if r2.req.sprn(0) = '0' then
                        sprval := x"00000000" & r3.dsisr;
                    else
                        sprval := r3.dar;
                    end if;
                else
                    -- reading one of the SPRs in the MMU
                    sprval := m_in.sprval;
                end if;
                done := '1';
            end if;
            if r2.req.use_splat = '1' then
                -- write splat data to destination
                write_enable := '1';
                done := '1';
            end if;
            if r2.req.align_intr = '1' then
                -- generate alignment interrupt
                exception := '1';
            end if;
            if r2.req.load_zero = '1' then
                write_enable := '1';
                done := '1';
            end if;
            if r2.req.do_update = '1' then
                do_update := '1';
                done := '1';
            end if;
            if r2.req.noop = '1' then
                done := '1';
            end if;
        end if;

        case r3.state is
        when IDLE =>
            if d_in.valid = '1' then
                if r2.req.two_dwords = '0' or r2.req.dword_index = '1' then
                    write_enable := r2.req.load and not r2.req.load_sp;
                    if HAS_FPU and r2.req.load_sp = '1' then
                        -- SP to DP conversion takes a cycle
                        v.state := FINISH_LFS;
                    else
                        -- stores write back rA update in this cycle
                        do_update := r2.req.update and r2.req.store;
                        done := '1';
                    end if;
                else
                    part_done := '1';
                end if;
            end if;
            if d_in.error = '1' then
                if d_in.cache_paradox = '1' then
                    -- signal an interrupt straight away
                    exception := '1';
                    dsisr(63 - 38) := not r2.req.load;
                    -- XXX there is no architected bit for this
                    -- (probably should be a machine check in fact)
                    dsisr(63 - 35) := d_in.cache_paradox;
                else
                    -- Look up the translation for TLB miss
                    -- and also for permission error and RC error
                    -- in case the PTE has been updated.
                    mmureq := '1';
                    v.state := MMU_LOOKUP;
                    v.stage1_en := '0';
                end if;
            end if;
            if r2.req.valid = '1' then
                if r2.req.mmu_op = '1' then
                    -- send request (tlbie, mtspr, itlb miss) to MMU
                    mmureq := not r2.req.write_spr;
                    mmu_mtspr := r2.req.write_spr;
                    if r2.req.instr_fault = '1' then
                        v.state := MMU_LOOKUP;
                    else
                        v.state := TLBIE_WAIT;
                    end if;
                elsif r2.req.write_spr = '1' then
                    if r2.req.sprn(0) = '0' then
                        v.dsisr := r2.req.store_data(31 downto 0);
                    else
                        v.dar := r2.req.store_data;
                    end if;
                    done := '1';
                end if;
            end if;

        when MMU_LOOKUP =>
            if m_in.done = '1' then
                if r2.req.instr_fault = '0' then
                    -- retry the request now that the MMU has installed a TLB entry
                    req := '1';
                    v.stage1_en := '1';
                    v.state := IDLE;
                else
                    done := '1';
                end if;
            end if;
            if m_in.err = '1' then
                exception := '1';
                dsisr(63 - 33) := m_in.invalid;
                dsisr(63 - 36) := m_in.perm_error;
                dsisr(63 - 38) := r2.req.store or r2.req.dcbz;
                dsisr(63 - 44) := m_in.badtree;
                dsisr(63 - 45) := m_in.rc_error;
            end if;

        when TLBIE_WAIT =>
            if m_in.done = '1' then
                done := '1';
            end if;

        when FINISH_LFS =>
            wr_sel := "10";
            write_enable := '1';
            done := '1';

        end case;

        if done = '1' or exception = '1' then
            v.stage1_en := '1';
            v.state := IDLE;
        end if;

        v.complete := done;
        v.write_enable := write_enable or do_update;
        v.write_reg := r2.req.write_reg;
        v.write_tag := r2.req.write_tag;
        if do_update = '1' then
            wr_sel := "01";
        end if;
        case wr_sel is
        when "00" =>
            -- mfspr result
            v.write_data := sprval;
        when "01" =>
            -- update reg
            v.write_data := r2.req.addr0;
        when "10" =>
            -- lfs result
            v.write_data := load_dp_data;
        when others =>
            -- load data
            v.write_data := data_trimmed;
        end case;
        v.xerc := r2.req.xerc;
        v.rc := r2.req.rc;
        v.write_cr_tag := r2.req.write_cr_tag;
        v.store_done := d_in.store_done;

        -- Update outputs to dcache
        if stage1_issue_enable = '1' then
            d_out.valid <= stage1_dcreq;
            d_out.load <= stage1_req.load;
            d_out.dcbz <= stage1_req.dcbz;
            d_out.nc <= stage1_req.nc;
            d_out.reserve <= stage1_req.reserve;
            d_out.atomic <= stage1_req.atomic;
            d_out.atomic_last <= stage1_req.atomic_last;
            d_out.addr <= stage1_req.addr;
            d_out.byte_sel <= stage1_req.byte_sel;
            d_out.virt_mode <= stage1_req.virt_mode;
            d_out.priv_mode <= stage1_req.priv_mode;
        else
            d_out.valid <= req;
            d_out.load <= r2.req.load;
            d_out.dcbz <= r2.req.dcbz;
            d_out.nc <= r2.req.nc;
            d_out.reserve <= r2.req.reserve;
            d_out.atomic <= r2.req.atomic;
            d_out.atomic_last <= r2.req.atomic_last;
            d_out.addr <= r2.req.addr;
            d_out.byte_sel <= r2.req.byte_sel;
            d_out.virt_mode <= r2.req.virt_mode;
            d_out.priv_mode <= r2.req.priv_mode;
        end if;
        if stage1_dreq = '1' then
            d_out.data <= store_data;
        else
            d_out.data <= r2.req.store_data;
        end if;

        -- Update outputs to MMU
        m_out.valid <= mmureq;
        m_out.iside <= r2.req.instr_fault;
        m_out.load <= r2.req.load;
        m_out.priv <= r2.req.priv_mode;
        m_out.tlbie <= r2.req.tlbie;
        m_out.mtspr <= mmu_mtspr;
        m_out.sprn <= r2.req.sprn;
        m_out.addr <= r2.req.addr;
        m_out.slbia <= r2.req.is_slbia;
        m_out.rs <= r2.req.store_data;

        -- Update outputs to writeback
        l_out.valid <= r3.complete;
        l_out.write_enable <= r3.write_enable;
        l_out.write_reg <= r3.write_reg;
        l_out.write_tag <= r3.write_tag;
        l_out.write_data <= r3.write_data;
        l_out.xerc <= r3.xerc;
        l_out.rc <= r3.rc and r3.complete;
        l_out.write_cr_tag <= r3.write_cr_tag;
        l_out.store_done <= r3.store_done;

        -- update exception info back to execute1
        e_out.busy <= busy;
        e_out.exception <= exception;
        e_out.alignment <= r2.req.align_intr;
        e_out.instr_fault <= r2.req.instr_fault;
        e_out.invalid <= m_in.invalid;
        e_out.badtree <= m_in.badtree;
        e_out.perm_error <= m_in.perm_error;
        e_out.rc_error <= m_in.rc_error;
        e_out.segment_fault <= m_in.segerr;
        if exception = '1' and r2.req.instr_fault = '0' then
            v.dar := r2.req.addr;
            if m_in.segerr = '0' and r2.req.align_intr = '0' then
                v.dsisr := dsisr;
            end if;
        end if;

        -- bypass data path back to decode2
        bypass_data.data <= v.write_data;
        bypass_data.tag.valid <= v.write_tag.valid and v.write_enable;
        bypass_data.tag.tag <= v.write_tag.tag;

        -- Busy calculation.
        stage3_busy_next <= r2.req.valid and (r2.req.dc_req or r2.req.mmu_op) and
                            not (done or part_done or exception);

        -- Update registers
        r3in <= v;

    end process;

    l1_log: if LOG_LENGTH > 0 generate
        signal log_data : std_ulogic_vector(9 downto 0);
    begin
        ls1_log: process(clk)
        begin
            if rising_edge(clk) then
                log_data <= e_out.busy &
                            e_out.exception &
                            l_out.valid &
                            m_out.valid &
                            d_out.valid &
                            m_in.done &
                            r2.req.dword_index &
                            std_ulogic_vector(to_unsigned(state_t'pos(r3.state), 3));
            end if;
        end process;
        log_out <= log_data;
    end generate;

end;
