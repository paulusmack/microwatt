-- Instruction pre-decoder for microwatt
-- Two cycles latency.  Does 'WIDTH' instructions in parallel.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.common.all;
use work.decode_types.all;
use work.insn_helpers.all;

entity predecoder is
    generic (
        HAS_FPU   : boolean := true;
        HAS_VECVSX   : boolean := true;
        WIDTH     : natural := 2;
        ICODE_LEN : natural := 22;
        IMAGE_LEN : natural := 26;
        ROWBITS   : natural := 3
        );
    port (
        clk        : in  std_ulogic;
        rst        : in  std_ulogic;
        valid_in   : in  std_ulogic;
        insns_in   : in  std_ulogic_vector(WIDTH * 32 - 1 downto 0);
        first_row  : in  std_ulogic;
        insn_index : in  unsigned(ROWBITS-1 downto 0);
        big_endian : in  std_ulogic;
        valid_out  : out std_ulogic;
        icodes_out : out std_ulogic_vector(WIDTH * (ICODE_LEN + IMAGE_LEN) - 1 downto 0)
        );
end entity predecoder;

architecture behaviour of predecoder is

    type reg_class_a_t is (NR, RA, FA, VA, XA);
    type reg_class_b_t is (NR, RB, FB, VB, XB);

    type reg_class_c_t is (
        NR,
        RC,
        FRC,
        VRC,
        RS,
        RSE,
        FRS,
        FRSE,
        VRS,
        VRSE,
        VRA,
        XS,
        XSE,
        XSR,
        XC,
        XA);
        
    type predec_insn is record
        areg : reg_class_a_t;
        breg : reg_class_b_t;
        creg : reg_class_c_t;
        insn : insn_code;
    end record;

    constant no_insn : predec_insn := (NR, NR, NR, INSN_illegal);

    type predecoder_rom_t is array(0 to 2047) of predec_insn;

    -- indexed by instruction bits 31..26 and 4..0
    constant major_predecode_rom : predecoder_rom_t := (
        2#000001_00000# to 2#000001_11111# => (NR, NR, NR,  INSN_prefix),
        2#001100_00000# to 2#001100_11111# => (RA, NR, NR,  INSN_addic),      -- 12
        2#001101_00000# to 2#001101_11111# => (RA, NR, NR,  INSN_addic_dot),  -- 13
        2#001110_00000# to 2#001110_11111# => (RA, NR, NR,  INSN_addi),       -- 14
        2#001111_00000# to 2#001111_11111# => (RA, NR, NR,  INSN_addis),      -- 15
        2#010011_00100# to 2#010011_00101# => (NR, NR, NR,  INSN_addpcis),    -- 19
        2#011100_00000# to 2#011100_11111# => (NR, NR, RS,  INSN_andi_dot),   -- 28
        2#011101_00000# to 2#011101_11111# => (NR, NR, RS,  INSN_andis_dot),  -- 29
        2#000000_00000#                    => (NR, NR, NR,  INSN_attn),       -- 0
        2#010010_00000# to 2#010010_00001# => (NR, NR, NR,  INSN_brel),       -- 18
        2#010010_00010# to 2#010010_00011# => (NR, NR, NR,  INSN_babs),
        2#010010_00100# to 2#010010_00101# => (NR, NR, NR,  INSN_brel),
        2#010010_00110# to 2#010010_00111# => (NR, NR, NR,  INSN_babs),
        2#010010_01000# to 2#010010_01001# => (NR, NR, NR,  INSN_brel),
        2#010010_01010# to 2#010010_01011# => (NR, NR, NR,  INSN_babs),
        2#010010_01100# to 2#010010_01101# => (NR, NR, NR,  INSN_brel),
        2#010010_01110# to 2#010010_01111# => (NR, NR, NR,  INSN_babs),
        2#010010_10000# to 2#010010_10001# => (NR, NR, NR,  INSN_brel),
        2#010010_10010# to 2#010010_10011# => (NR, NR, NR,  INSN_babs),
        2#010010_10100# to 2#010010_10101# => (NR, NR, NR,  INSN_brel),
        2#010010_10110# to 2#010010_10111# => (NR, NR, NR,  INSN_babs),
        2#010010_11000# to 2#010010_11001# => (NR, NR, NR,  INSN_brel),
        2#010010_11010# to 2#010010_11011# => (NR, NR, NR,  INSN_babs),
        2#010010_11100# to 2#010010_11101# => (NR, NR, NR,  INSN_brel),
        2#010010_11110# to 2#010010_11111# => (NR, NR, NR,  INSN_babs),
        2#010000_00000# to 2#010000_00001# => (NR, NR, NR,  INSN_bcrel),      -- 16
        2#010000_00010# to 2#010000_00011# => (NR, NR, NR,  INSN_bcabs),
        2#010000_00100# to 2#010000_00101# => (NR, NR, NR,  INSN_bcrel),
        2#010000_00110# to 2#010000_00111# => (NR, NR, NR,  INSN_bcabs),
        2#010000_01000# to 2#010000_01001# => (NR, NR, NR,  INSN_bcrel),
        2#010000_01010# to 2#010000_01011# => (NR, NR, NR,  INSN_bcabs),
        2#010000_01100# to 2#010000_01101# => (NR, NR, NR,  INSN_bcrel),
        2#010000_01110# to 2#010000_01111# => (NR, NR, NR,  INSN_bcabs),
        2#010000_10000# to 2#010000_10001# => (NR, NR, NR,  INSN_bcrel),
        2#010000_10010# to 2#010000_10011# => (NR, NR, NR,  INSN_bcabs),
        2#010000_10100# to 2#010000_10101# => (NR, NR, NR,  INSN_bcrel),
        2#010000_10110# to 2#010000_10111# => (NR, NR, NR,  INSN_bcabs),
        2#010000_11000# to 2#010000_11001# => (NR, NR, NR,  INSN_bcrel),
        2#010000_11010# to 2#010000_11011# => (NR, NR, NR,  INSN_bcabs),
        2#010000_11100# to 2#010000_11101# => (NR, NR, NR,  INSN_bcrel),
        2#010000_11110# to 2#010000_11111# => (NR, NR, NR,  INSN_bcabs),
        2#001011_00000# to 2#001011_11111# => (RA, NR, NR,  INSN_cmpi),       -- 11
        2#001010_00000# to 2#001010_11111# => (RA, NR, NR,  INSN_cmpli),      -- 10
        2#100010_00000# to 2#100010_11111# => (RA, NR, NR,  INSN_lbz),        -- 34
        2#100011_00000# to 2#100011_11111# => (RA, NR, NR,  INSN_lbzu),       -- 35
        2#110010_00000# to 2#110010_11111# => (RA, NR, NR,  INSN_lfd),        -- 50
        2#110011_00000# to 2#110011_11111# => (RA, NR, NR,  INSN_lfdu),       -- 51
        2#110000_00000# to 2#110000_11111# => (RA, NR, NR,  INSN_lfs),        -- 48
        2#110001_00000# to 2#110001_11111# => (RA, NR, NR,  INSN_lfsu),       -- 49
        2#101010_00000# to 2#101010_11111# => (RA, NR, NR,  INSN_lha),        -- 42
        2#101011_00000# to 2#101011_11111# => (RA, NR, NR,  INSN_lhau),       -- 43
        2#101000_00000# to 2#101000_11111# => (RA, NR, NR,  INSN_lhz),        -- 40
        2#101001_00000# to 2#101001_11111# => (RA, NR, NR,  INSN_lhzu),       -- 41
        2#100000_00000# to 2#100000_11111# => (RA, NR, NR,  INSN_lwz),        -- 32
        2#100001_00000# to 2#100001_11111# => (RA, NR, NR,  INSN_lwzu),       -- 33
        2#000111_00000# to 2#000111_11111# => (RA, NR, NR,  INSN_mulli),      -- 7
        2#011000_00000# to 2#011000_11111# => (NR, NR, RS,  INSN_ori),        -- 24
        2#011001_00000# to 2#011001_11111# => (NR, NR, RS,  INSN_oris),       -- 25
        2#010100_00000# to 2#010100_11111# => (RA, NR, RS,  INSN_rlwimi),     -- 20
        2#010101_00000# to 2#010101_11111# => (NR, NR, RS,  INSN_rlwinm),     -- 21
        2#010111_00000# to 2#010111_11111# => (NR, RB, RS,  INSN_rlwnm),      -- 23
        2#010001_00000# to 2#010001_11111# => (NR, NR, NR,  INSN_sc),         -- 17
        2#100110_00000# to 2#100110_11111# => (RA, NR, RS,  INSN_stb),        -- 38
        2#100111_00000# to 2#100111_11111# => (RA, NR, RS,  INSN_stbu),       -- 39
        2#110110_00000# to 2#110110_11111# => (RA, NR, FRS, INSN_stfd),       -- 54
        2#110111_00000# to 2#110111_11111# => (RA, NR, FRS, INSN_stfdu),      -- 55
        2#110100_00000# to 2#110100_11111# => (RA, NR, FRS, INSN_stfs),       -- 52
        2#110101_00000# to 2#110101_11111# => (RA, NR, FRS, INSN_stfsu),      -- 53
        2#101100_00000# to 2#101100_11111# => (RA, NR, RS,  INSN_sth),        -- 44
        2#101101_00000# to 2#101101_11111# => (RA, NR, RS,  INSN_sthu),       -- 45
        2#100100_00000# to 2#100100_11111# => (RA, NR, RS,  INSN_stw),        -- 36
        2#100101_00000# to 2#100101_11111# => (RA, NR, RS,  INSN_stwu),       -- 37
        2#001000_00000# to 2#001000_11111# => (RA, NR, NR,  INSN_subfic),     -- 8
        2#000010_00000# to 2#000010_11111# => (RA, NR, NR,  INSN_tdi),        -- 2
        2#000011_00000# to 2#000011_11111# => (RA, NR, NR,  INSN_twi),        -- 3
        2#011010_00000# to 2#011010_11111# => (NR, NR, RS,  INSN_xori),       -- 26
        2#011011_00000# to 2#011011_11111# => (NR, NR, RS,  INSN_xoris),      -- 27
        -- major opcode 4
        2#000100_00000# to 2#000100_01111# => (RA, RB, RC,  INSN_vemu),
        2#000100_10000#                    => (RA, RB, RC,  INSN_maddhd),
        2#000100_10001#                    => (RA, RB, RC,  INSN_maddhdu),
        2#000100_10011#                    => (RA, RB, RC,  INSN_maddld),
        2#000100_10100# to 2#000100_11111# => (RA, RB, RC,  INSN_vemu),
        -- major opcode 22 (sandbox)
        2#010110_00000#                    => (RA, NR, NR,  INSN_mfrin),
        2#010110_00001#                    => (RA, NR, RS,  INSN_mtrin),
        -- major opcode 30
        2#011110_01000# to 2#011110_01001# => (NR, NR, RS,  INSN_rldic),
        2#011110_01010# to 2#011110_01011# => (NR, NR, RS,  INSN_rldic),
        2#011110_00000# to 2#011110_00001# => (NR, NR, RS,  INSN_rldicl),
        2#011110_00010# to 2#011110_00011# => (NR, NR, RS,  INSN_rldicl),
        2#011110_00100# to 2#011110_00101# => (NR, NR, RS,  INSN_rldicr),
        2#011110_00110# to 2#011110_00111# => (NR, NR, RS,  INSN_rldicr),
        2#011110_01100# to 2#011110_01101# => (RA, NR, RS,  INSN_rldimi),
        2#011110_01110# to 2#011110_01111# => (RA, NR, RS,  INSN_rldimi),
        2#011110_10000# to 2#011110_10001# => (NR, RB, RS,  INSN_rldcl),
        2#011110_10010# to 2#011110_10011# => (NR, RB, RS,  INSN_rldcr),
        -- major opcode 56
        2#111000_00000# to 2#111000_11111# => (RA, NR, NR,  INSN_lq),
        -- major opcode 57
        2#111001_00010#                    => (RA, NR, NR,  INSN_lxsd),
        2#111001_00110#                    => (RA, NR, NR,  INSN_lxsd),
        2#111001_01010#                    => (RA, NR, NR,  INSN_lxsd),
        2#111001_01110#                    => (RA, NR, NR,  INSN_lxsd),
        2#111001_10010#                    => (RA, NR, NR,  INSN_lxsd),
        2#111001_10110#                    => (RA, NR, NR,  INSN_lxsd),
        2#111001_11010#                    => (RA, NR, NR,  INSN_lxsd),
        2#111001_11110#                    => (RA, NR, NR,  INSN_lxsd),
        2#111001_00011#                    => (RA, NR, NR,  INSN_lxssp),
        2#111001_00111#                    => (RA, NR, NR,  INSN_lxssp),
        2#111001_01011#                    => (RA, NR, NR,  INSN_lxssp),
        2#111001_01111#                    => (RA, NR, NR,  INSN_lxssp),
        2#111001_10011#                    => (RA, NR, NR,  INSN_lxssp),
        2#111001_10111#                    => (RA, NR, NR,  INSN_lxssp),
        2#111001_11011#                    => (RA, NR, NR,  INSN_lxssp),
        2#111001_11111#                    => (RA, NR, NR,  INSN_lxssp),
        -- major opcode 58
        2#111010_00000#                    => (RA, NR, NR,  INSN_ld),
        2#111010_00001#                    => (RA, NR, NR,  INSN_ldu),
        2#111010_00010#                    => (RA, NR, NR,  INSN_lwa),
        2#111010_00100#                    => (RA, NR, NR,  INSN_ld),
        2#111010_00101#                    => (RA, NR, NR,  INSN_ldu),
        2#111010_00110#                    => (RA, NR, NR,  INSN_lwa),
        2#111010_01000#                    => (RA, NR, NR,  INSN_ld),
        2#111010_01001#                    => (RA, NR, NR,  INSN_ldu),
        2#111010_01010#                    => (RA, NR, NR,  INSN_lwa),
        2#111010_01100#                    => (RA, NR, NR,  INSN_ld),
        2#111010_01101#                    => (RA, NR, NR,  INSN_ldu),
        2#111010_01110#                    => (RA, NR, NR,  INSN_lwa),
        2#111010_10000#                    => (RA, NR, NR,  INSN_ld),
        2#111010_10001#                    => (RA, NR, NR,  INSN_ldu),
        2#111010_10010#                    => (RA, NR, NR,  INSN_lwa),
        2#111010_10100#                    => (RA, NR, NR,  INSN_ld),
        2#111010_10101#                    => (RA, NR, NR,  INSN_ldu),
        2#111010_10110#                    => (RA, NR, NR,  INSN_lwa),
        2#111010_11000#                    => (RA, NR, NR,  INSN_ld),
        2#111010_11001#                    => (RA, NR, NR,  INSN_ldu),
        2#111010_11010#                    => (RA, NR, NR,  INSN_lwa),
        2#111010_11100#                    => (RA, NR, NR,  INSN_ld),
        2#111010_11101#                    => (RA, NR, NR,  INSN_ldu),
        2#111010_11110#                    => (RA, NR, NR,  INSN_lwa),
        -- major opcode 59
        2#111011_00100# to 2#111011_00101# => (FA, FB, NR,  INSN_fdivs),
        2#111011_01000# to 2#111011_01001# => (FA, FB, NR,  INSN_fsubs),
        2#111011_01010# to 2#111011_01011# => (FA, FB, NR,  INSN_fadds),
        2#111011_01100# to 2#111011_01101# => (NR, FB, NR,  INSN_fsqrts),
        2#111011_10000# to 2#111011_10001# => (NR, FB, NR,  INSN_fres),
        2#111011_10010# to 2#111011_10011# => (FA, NR, FRC, INSN_fmuls),
        2#111011_10100# to 2#111011_10101# => (NR, FB, NR,  INSN_frsqrtes),
        2#111011_11000# to 2#111011_11001# => (FA, FB, FRC, INSN_fmsubs),
        2#111011_11010# to 2#111011_11011# => (FA, FB, FRC, INSN_fmadds),
        2#111011_11100# to 2#111011_11101# => (FA, FB, FRC, INSN_fnmsubs),
        2#111011_11110# to 2#111011_11111# => (FA, FB, FRC, INSN_fnmadds),
        -- major opcode 61
        2#111101_00001#                    => (RA, NR, NR,   INSN_lxv),
        2#111101_01001#                    => (RA, NR, NR,   INSN_lxv),
        2#111101_10001#                    => (RA, NR, NR,   INSN_lxv),
        2#111101_11001#                    => (RA, NR, NR,   INSN_lxv),
        2#111101_00101#                    => (RA, RB, FRSE, INSN_stxv_fp),
        2#111101_01101#                    => (RA, RB, VRSE, INSN_stxv_vec),
        2#111101_10101#                    => (RA, RB, FRSE, INSN_stxv_fp),
        2#111101_11101#                    => (RA, RB, VRSE, INSN_stxv_vec),
        2#111101_00010#                    => (RA, NR, VRS,  INSN_stxsd),
        2#111101_00110#                    => (RA, NR, VRS,  INSN_stxsd),
        2#111101_01010#                    => (RA, NR, VRS,  INSN_stxsd),
        2#111101_01110#                    => (RA, NR, VRS,  INSN_stxsd),
        2#111101_10010#                    => (RA, NR, VRS,  INSN_stxsd),
        2#111101_10110#                    => (RA, NR, VRS,  INSN_stxsd),
        2#111101_11010#                    => (RA, NR, VRS,  INSN_stxsd),
        2#111101_11110#                    => (RA, NR, VRS,  INSN_stxsd),
        2#111101_00011#                    => (RA, NR, VRS,  INSN_stxssp),
        2#111101_00111#                    => (RA, NR, VRS,  INSN_stxssp),
        2#111101_01011#                    => (RA, NR, VRS,  INSN_stxssp),
        2#111101_01111#                    => (RA, NR, VRS,  INSN_stxssp),
        2#111101_10011#                    => (RA, NR, VRS,  INSN_stxssp),
        2#111101_10111#                    => (RA, NR, VRS,  INSN_stxssp),
        2#111101_11011#                    => (RA, NR, VRS,  INSN_stxssp),
        2#111101_11111#                    => (RA, NR, VRS,  INSN_stxssp),
        -- major opcode 62
        2#111110_00000#                    => (NR, NR, RS,  INSN_std),
        2#111110_00001#                    => (NR, NR, RS,  INSN_stdu),
        2#111110_00010#                    => (NR, NR, RSE, INSN_stq),
        2#111110_00100#                    => (NR, NR, RS,  INSN_std),
        2#111110_00101#                    => (NR, NR, RS,  INSN_stdu),
        2#111110_00110#                    => (NR, NR, RSE, INSN_stq),
        2#111110_01000#                    => (NR, NR, RS,  INSN_std),
        2#111110_01001#                    => (NR, NR, RS,  INSN_stdu),
        2#111110_01010#                    => (NR, NR, RSE, INSN_stq),
        2#111110_01100#                    => (NR, NR, RS,  INSN_std),
        2#111110_01101#                    => (NR, NR, RS,  INSN_stdu),
        2#111110_01110#                    => (NR, NR, RSE, INSN_stq),
        2#111110_10000#                    => (NR, NR, RS,  INSN_std),
        2#111110_10001#                    => (NR, NR, RS,  INSN_stdu),
        2#111110_10010#                    => (NR, NR, RSE, INSN_stq),
        2#111110_10100#                    => (NR, NR, RS,  INSN_std),
        2#111110_10101#                    => (NR, NR, RS,  INSN_stdu),
        2#111110_10110#                    => (NR, NR, RSE, INSN_stq),
        2#111110_11000#                    => (NR, NR, RS,  INSN_std),
        2#111110_11001#                    => (NR, NR, RS,  INSN_stdu),
        2#111110_11010#                    => (NR, NR, RSE, INSN_stq),
        2#111110_11100#                    => (NR, NR, RS,  INSN_std),
        2#111110_11101#                    => (NR, NR, RS,  INSN_stdu),
        2#111110_11110#                    => (NR, NR, RSE, INSN_stq),
        -- major opcode 63
        2#111111_00100# to 2#111111_00101# => (FA, FB, NR,  INSN_fdiv),
        2#111111_01000# to 2#111111_01001# => (FA, FB, NR,  INSN_fsub),
        2#111111_01010# to 2#111111_01011# => (FA, FB, NR,  INSN_fadd),
        2#111111_01100# to 2#111111_01101# => (NR, FB, NR,  INSN_fsqrt),
        2#111111_01110# to 2#111111_01111# => (FA, FB, FRC, INSN_fsel),
        2#111111_10000# to 2#111111_10001# => (NR, FB, NR,  INSN_fre),
        2#111111_10010# to 2#111111_10011# => (FA, NR, FRC, INSN_fmul),
        2#111111_10100# to 2#111111_10101# => (NR, FB, NR,  INSN_frsqrte),
        2#111111_11000# to 2#111111_11001# => (FA, FB, FRC, INSN_fmsub),
        2#111111_11010# to 2#111111_11011# => (FA, FB, FRC, INSN_fmadd),
        2#111111_11100# to 2#111111_11101# => (FA, FB, FRC, INSN_fnmsub),
        2#111111_11110# to 2#111111_11111# => (FA, FB, FRC, INSN_fnmadd),

        others                             => (NR, NR, NR, INSN_illegal)
        );

    constant row_predecode_rom : predecoder_rom_t := (
        -- Major opcode 31
        -- Address bits are 0, insn(10:1)
        2#0_01000_01010#  => (RA, RB, NR,   INSN_add),
        2#0_11000_01010#  => (RA, RB, NR,   INSN_add), -- addo
        2#0_00000_01010#  => (RA, RB, NR,   INSN_addc),
        2#0_10000_01010#  => (RA, RB, NR,   INSN_addc), -- addco
        2#0_00100_01010#  => (RA, RB, NR,   INSN_adde),
        2#0_10100_01010#  => (RA, RB, NR,   INSN_adde), -- addeo
        2#0_00101_01010#  => (RA, RB, NR,   INSN_addex),
        2#0_00010_01010#  => (RA, RB, NR,   INSN_addg6s),
        2#0_00111_01010#  => (RA, NR, NR,   INSN_addme),
        2#0_10111_01010#  => (RA, NR, NR,   INSN_addme), -- addmeo
        2#0_00110_01010#  => (RA, NR, NR,   INSN_addze),
        2#0_10110_01010#  => (RA, NR, NR,   INSN_addze), -- addzeo
        2#0_00000_11100#  => (NR, RB, RS,   INSN_and),
        2#0_00001_11100#  => (NR, RB, RS,   INSN_andc),
        2#0_00111_11100#  => (NR, RB, RS,   INSN_bperm),
        2#0_00110_11011#  => (NR, NR, RS,   INSN_brh),
        2#0_00100_11011#  => (NR, NR, RS,   INSN_brw),
        2#0_00101_11011#  => (NR, NR, RS,   INSN_brd),
        2#0_01001_11010#  => (NR, NR, RS,   INSN_cbcdtd),
        2#0_01000_11010#  => (NR, NR, RS,   INSN_cdtbcd),
        2#0_00110_11100#  => (NR, RB, RS,   INSN_cfuged),
        2#0_00000_00000#  => (RA, RB, NR,   INSN_cmp),
        2#0_01111_11100#  => (NR, RB, RS,   INSN_cmpb),
        2#0_00111_00000#  => (RA, RB, NR,   INSN_cmpeqb),
        2#0_00001_00000#  => (RA, RB, NR,   INSN_cmpl),
        2#0_00110_00000#  => (RA, RB, NR,   INSN_cmprb),
        2#0_00001_11010#  => (NR, NR, RS,   INSN_cntlzd),
        2#0_00000_11010#  => (NR, NR, RS,   INSN_cntlzw),
        2#0_10001_11010#  => (NR, NR, RS,   INSN_cnttzd),
        2#0_10000_11010#  => (NR, NR, RS,   INSN_cnttzw),
        2#0_11010_00110#  => (NR, NR, NR,   INSN_rnop), -- cpabort
        2#0_10111_10011#  => (NR, NR, NR,   INSN_darn),
        2#0_00010_10110#  => (RA, RB, NR,   INSN_dcbf),
        2#0_00001_10110#  => (RA, RB, NR,   INSN_dcbst),
        2#0_01000_10110#  => (RA, RB, NR,   INSN_dcbt),
        2#0_00111_10110#  => (RA, RB, NR,   INSN_dcbtst),
        2#0_11111_10110#  => (RA, RB, NR,   INSN_dcbz),
        2#0_01100_01001#  => (RA, RB, NR,   INSN_divdeu),
        2#0_11100_01001#  => (RA, RB, NR,   INSN_divdeu), -- divdeuo
        2#0_01100_01011#  => (RA, RB, NR,   INSN_divweu),
        2#0_11100_01011#  => (RA, RB, NR,   INSN_divweu), -- divweuo
        2#0_01101_01001#  => (RA, RB, NR,   INSN_divde),
        2#0_11101_01001#  => (RA, RB, NR,   INSN_divde), -- divdeo
        2#0_01101_01011#  => (RA, RB, NR,   INSN_divwe),
        2#0_11101_01011#  => (RA, RB, NR,   INSN_divwe), -- divweo
        2#0_01110_01001#  => (RA, RB, NR,   INSN_divdu),
        2#0_11110_01001#  => (RA, RB, NR,   INSN_divdu), -- divduo
        2#0_01110_01011#  => (RA, RB, NR,   INSN_divwu),
        2#0_11110_01011#  => (RA, RB, NR,   INSN_divwu), -- divwuo
        2#0_01111_01001#  => (RA, RB, NR,   INSN_divd),
        2#0_11111_01001#  => (RA, RB, NR,   INSN_divd), -- divdo
        2#0_01111_01011#  => (RA, RB, NR,   INSN_divw),
        2#0_11111_01011#  => (RA, RB, NR,   INSN_divw), -- divwo
        2#0_11001_10110#  => (NR, NR, NR,   INSN_rnop), -- dss
        2#0_01010_10110#  => (NR, NR, NR,   INSN_rnop), -- dst
        2#0_01011_10110#  => (NR, NR, NR,   INSN_rnop), -- dstst
        2#0_11010_10110#  => (NR, NR, NR,   INSN_eieio),
        2#0_01000_11100#  => (NR, RB, RS,   INSN_eqv),
        2#0_11101_11010#  => (NR, NR, RS,   INSN_extsb),
        2#0_11100_11010#  => (NR, NR, RS,   INSN_extsh),
        2#0_11110_11010#  => (NR, NR, RS,   INSN_extsw),
        2#0_11011_11010#  => (NR, NR, RS,   INSN_extswsli),
        2#0_11011_11011#  => (NR, NR, RS,   INSN_extswsli),
        2#0_11110_10110#  => (RA, RB, NR,   INSN_icbi),
        2#0_00000_10110#  => (RA, RB, NR,   INSN_icbt),
        2#0_00000_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_00001_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_00010_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_00011_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_00100_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_00101_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_00110_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_00111_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_01000_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_01001_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_01010_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_01011_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_01100_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_01101_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_01110_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_01111_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_10000_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_10001_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_10010_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_10011_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_10100_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_10101_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_10110_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_10111_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_11000_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_11001_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_11010_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_11011_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_11100_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_11101_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_11110_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_11111_01111#  => (RA, RB, NR,   INSN_isel),
        2#0_00001_10100#  => (RA, RB, NR,   INSN_lbarx),
        2#0_11010_10101#  => (RA, RB, NR,   INSN_lbzcix),
        2#0_00011_10111#  => (RA, RB, NR,   INSN_lbzux),
        2#0_00010_10111#  => (RA, RB, NR,   INSN_lbzx),
        2#0_00010_10100#  => (RA, RB, NR,   INSN_ldarx),
        2#0_10000_10100#  => (RA, RB, NR,   INSN_ldbrx),
        2#0_11011_10101#  => (RA, RB, NR,   INSN_ldcix),
        2#0_00001_10101#  => (RA, RB, NR,   INSN_ldux),
        2#0_00000_10101#  => (RA, RB, NR,   INSN_ldx),
        2#0_10010_10111#  => (RA, RB, NR,   INSN_lfdx),
        2#0_10011_10111#  => (RA, RB, NR,   INSN_lfdux),
        2#0_11010_10111#  => (RA, RB, NR,   INSN_lfiwax),
        2#0_11011_10111#  => (RA, RB, NR,   INSN_lfiwzx),
        2#0_10000_10111#  => (RA, RB, NR,   INSN_lfsx),
        2#0_10001_10111#  => (RA, RB, NR,   INSN_lfsux),
        2#0_00011_10100#  => (RA, RB, NR,   INSN_lharx),
        2#0_01011_10111#  => (RA, RB, NR,   INSN_lhaux),
        2#0_01010_10111#  => (RA, RB, NR,   INSN_lhax),
        2#0_11000_10110#  => (RA, RB, NR,   INSN_lhbrx),
        2#0_11001_10101#  => (RA, RB, NR,   INSN_lhzcix),
        2#0_01001_10111#  => (RA, RB, NR,   INSN_lhzux),
        2#0_01000_10111#  => (RA, RB, NR,   INSN_lhzx),
        2#0_01000_10100#  => (RA, RB, NR,   INSN_lqarx),
        2#0_00000_00111#  => (RA, RB, NR,   INSN_lvebx),
        2#0_00001_00111#  => (RA, RB, NR,   INSN_lvehx),
        2#0_00010_00111#  => (RA, RB, NR,   INSN_lvewx),
        2#0_00011_00111#  => (RA, RB, NR,   INSN_lvx),
        2#0_01011_00111#  => (RA, RB, NR,   INSN_lvxl),
        2#0_00000_10100#  => (RA, RB, NR,   INSN_lwarx),
        2#0_01011_10101#  => (RA, RB, NR,   INSN_lwaux),
        2#0_01010_10101#  => (RA, RB, NR,   INSN_lwax),
        2#0_10000_10110#  => (RA, RB, NR,   INSN_lwbrx),
        2#0_11000_10101#  => (RA, RB, NR,   INSN_lwzcix),
        2#0_00001_10111#  => (RA, RB, NR,   INSN_lwzux),
        2#0_00000_10111#  => (RA, RB, NR,   INSN_lwzx),
        2#0_10010_01100#  => (RA, RB, NR,   INSN_lxsdx),
        2#0_11000_01101#  => (RA, RB, NR,   INSN_lxsibzx),
        2#0_11001_01101#  => (RA, RB, NR,   INSN_lxsihzx),
        2#0_00010_01100#  => (RA, RB, NR,   INSN_lxsiwax),
        2#0_00000_01100#  => (RA, RB, NR,   INSN_lxsiwzx),
        2#0_10000_01100#  => (RA, RB, NR,   INSN_lxsspx),
        2#0_11011_01100#  => (RA, RB, NR,   INSN_lxvb16x),
        2#0_11010_01100#  => (RA, RB, NR,   INSN_lxvd2x),
        2#0_11001_01100#  => (RA, RB, NR,   INSN_lxvh8x),
        2#0_11000_01100#  => (RA, RB, NR,   INSN_lxvw4x),
        2#0_01000_01100#  => (RA, RB, NR,   INSN_lxvx),
        2#0_01001_01100#  => (RA, RB, NR,   INSN_lxvx),
        2#0_01010_01100#  => (RA, RB, NR,   INSN_lxvdsx),
        2#0_01011_01100#  => (RA, RB, NR,   INSN_lxvwsx),
        2#0_00000_01101#  => (RA, RB, NR,   INSN_lxvrbx),
        2#0_00011_01101#  => (RA, RB, NR,   INSN_lxvrdx),
        2#0_00001_01101#  => (RA, RB, NR,   INSN_lxvrhx),
        2#0_00010_01101#  => (RA, RB, NR,   INSN_lxvrwx),
        2#0_01000_01101#  => (RA, RB, NR,   INSN_lxvl),
        2#0_01001_01101#  => (RA, RB, NR,   INSN_lxvll),
        2#0_10010_00000#  => (NR, NR, NR,   INSN_mcrxrx),
        2#0_00000_10011#  => (NR, NR, NR,   INSN_mfcr),
        2#0_00010_10011#  => (NR, NR, NR,   INSN_mfmsr),
        2#0_01010_10011#  => (NR, NR, RS,   INSN_mfspr),
        2#0_00001_10011#  => (NR, NR, XS,   INSN_mfvsrd),
        2#0_01001_10011#  => (NR, NR, XSR,  INSN_mfvsrld),
        2#0_00011_10011#  => (NR, NR, XS,   INSN_mfvsrwz),
        2#0_01000_01001#  => (RA, RB, NR,   INSN_modud),
        2#0_01000_01011#  => (RA, RB, NR,   INSN_moduw),
        2#0_11000_01001#  => (RA, RB, NR,   INSN_modsd),
        2#0_11000_01011#  => (RA, RB, NR,   INSN_modsw),
        2#0_00100_10000#  => (NR, NR, RS,   INSN_mtcrf),
        2#0_00100_10010#  => (NR, NR, RS,   INSN_mtmsr),
        2#0_00101_10010#  => (NR, NR, RS,   INSN_mtmsrd),
        2#0_01110_10011#  => (NR, NR, RS,   INSN_mtspr),
        2#0_00101_10011#  => (RA, NR, NR,   INSN_mtvsrd),
        2#0_00110_10011#  => (RA, NR, NR,   INSN_mtvsrwa),
        2#0_00111_10011#  => (RA, NR, NR,   INSN_mtvsrwz),
        2#0_01101_10011#  => (RA, RB, NR,   INSN_mtvsrdd),
        2#0_01100_10011#  => (RA, NR, NR,   INSN_mtvsrws),
        2#0_00010_01001#  => (RA, RB, NR,   INSN_mulhd),
        2#0_00000_01001#  => (RA, RB, NR,   INSN_mulhdu),
        2#0_00010_01011#  => (RA, RB, NR,   INSN_mulhw),
        2#0_00000_01011#  => (RA, RB, NR,   INSN_mulhwu),
        -- next 4 have reserved bit set
        2#0_10010_01001#  => (RA, RB, NR,   INSN_mulhd),
        2#0_10000_01001#  => (RA, RB, NR,   INSN_mulhdu),
        2#0_10010_01011#  => (RA, RB, NR,   INSN_mulhw),
        2#0_10000_01011#  => (RA, RB, NR,   INSN_mulhwu),
        2#0_00111_01001#  => (RA, RB, NR,   INSN_mulld),
        2#0_10111_01001#  => (RA, RB, NR,   INSN_mulld), -- mulldo
        2#0_00111_01011#  => (RA, RB, NR,   INSN_mullw),
        2#0_10111_01011#  => (RA, RB, NR,   INSN_mullw), -- mullwo
        2#0_01110_11100#  => (NR, RB, RS,   INSN_nand),
        2#0_00011_01000#  => (RA, NR, NR,   INSN_neg),
        2#0_10011_01000#  => (RA, NR, NR,   INSN_neg), -- nego
        -- next 4 are reserved no-op instructions
        2#0_10000_10010#  => (NR, NR, NR,   INSN_rnop),
        2#0_10001_10010#  => (NR, NR, NR,   INSN_rnop),
        2#0_10010_10010#  => (NR, NR, NR,   INSN_rnop),
        2#0_10011_10010#  => (NR, NR, NR,   INSN_rnop),
        2#0_10110_10010#  => (NR, NR, NR,   INSN_hashst),
        2#0_10111_10010#  => (RA, RB, NR,   INSN_hashchk),
        2#0_10100_10010#  => (RA, RB, NR,   INSN_hashstp),
        2#0_10101_10010#  => (RA, RB, NR,   INSN_hashchkp),
        2#0_00011_11100#  => (NR, RB, RS,   INSN_nor),
        2#0_01101_11100#  => (NR, RB, RS,   INSN_or),
        2#0_01100_11100#  => (NR, RB, RS,   INSN_orc),
        2#0_00100_11100#  => (NR, RB, RS,   INSN_pdepd),
        2#0_00101_11100#  => (NR, RB, RS,   INSN_pextd),
        2#0_00011_11010#  => (NR, NR, RS,   INSN_popcntb),
        2#0_01111_11010#  => (NR, NR, RS,   INSN_popcntd),
        2#0_01011_11010#  => (NR, NR, RS,   INSN_popcntw),
        2#0_00101_11010#  => (NR, NR, RS,   INSN_prtyd),
        2#0_00100_11010#  => (NR, NR, RS,   INSN_prtyw),
        2#0_00100_00000#  => (NR, NR, NR,   INSN_setb),
        2#0_01100_00000#  => (NR, NR, NR,   INSN_setb), -- setbc
        2#0_01101_00000#  => (NR, NR, NR,   INSN_setb), -- setbcr
        2#0_01110_00000#  => (NR, NR, NR,   INSN_setb), -- setnbc
        2#0_01111_00000#  => (NR, NR, NR,   INSN_setb), -- setnbcr
        2#0_01111_10010#  => (NR, NR, NR,   INSN_slbia),
        2#0_00000_11011#  => (NR, RB, RS,   INSN_sld),
        2#0_00000_11000#  => (NR, RB, RS,   INSN_slw),
        2#0_11000_11010#  => (NR, RB, RS,   INSN_srad),
        2#0_11001_11010#  => (NR, RB, RS,   INSN_sradi),
        2#0_11001_11011#  => (NR, RB, RS,   INSN_sradi),
        2#0_11000_11000#  => (NR, RB, RS,   INSN_sraw),
        2#0_11001_11000#  => (NR, RB, RS,   INSN_srawi),
        2#0_10000_11011#  => (NR, RB, RS,   INSN_srd),
        2#0_10000_11000#  => (NR, RB, RS,   INSN_srw),
        2#0_11110_10101#  => (RA, RB, RS,   INSN_stbcix),
        2#0_10101_10110#  => (RA, RB, RS,   INSN_stbcx),
        2#0_00111_10111#  => (RA, RB, RS,   INSN_stbux),
        2#0_00110_10111#  => (RA, RB, RS,   INSN_stbx),
        2#0_10100_10100#  => (RA, RB, RS,   INSN_stdbrx),
        2#0_11111_10101#  => (RA, RB, RS,   INSN_stdcix),
        2#0_00110_10110#  => (RA, RB, RS,   INSN_stdcx),
        2#0_00101_10101#  => (RA, RB, RS,   INSN_stdux),
        2#0_00100_10101#  => (RA, RB, RS,   INSN_stdx),
        2#0_10110_10111#  => (RA, RB, FRS,  INSN_stfdx),
        2#0_10111_10111#  => (RA, RB, FRS,  INSN_stfdux),
        2#0_11110_10111#  => (RA, RB, FRS,  INSN_stfiwx),
        2#0_10100_10111#  => (RA, RB, FRS,  INSN_stfsx),
        2#0_10101_10111#  => (RA, RB, FRS,  INSN_stfsux),
        2#0_11100_10110#  => (RA, RB, RS,   INSN_sthbrx),
        2#0_11101_10101#  => (RA, RB, RS,   INSN_sthcix),
        2#0_10110_10110#  => (RA, RB, RS,   INSN_sthcx),
        2#0_01101_10111#  => (RA, RB, RS,   INSN_sthux),
        2#0_01100_10111#  => (RA, RB, RS,   INSN_sthx),
        2#0_00101_10110#  => (RA, RB, RSE,  INSN_stqcx),
        2#0_00100_00111#  => (RA, RB, VRSE, INSN_stvebx),
        2#0_00101_00111#  => (RA, RB, VRSE, INSN_stvehx),
        2#0_00110_00111#  => (RA, RB, VRSE, INSN_stvewx),
        2#0_00111_00111#  => (RA, RB, VRSE, INSN_stvx),
        2#0_01111_00111#  => (RA, RB, VRSE, INSN_stvxl),
        2#0_10100_10110#  => (RA, RB, RS,   INSN_stwbrx),
        2#0_11100_10101#  => (RA, RB, RS,   INSN_stwcix),
        2#0_00100_10110#  => (RA, RB, RS,   INSN_stwcx),
        2#0_00101_10111#  => (RA, RB, RS,   INSN_stwux),
        2#0_00100_10111#  => (RA, RB, RS,   INSN_stwx),
        2#0_10110_01100#  => (RA, RB, XS,   INSN_stxsdx),
        2#0_11100_01101#  => (RA, RB, XS,   INSN_stxsibx),
        2#0_11101_01101#  => (RA, RB, XS,   INSN_stxsihx),
        2#0_00100_01100#  => (RA, RB, XS,   INSN_stxsiwx),
        2#0_10100_01100#  => (RA, RB, XS,   INSN_stxsspx),
        2#0_11111_01100#  => (RA, RB, XS,   INSN_stxvb16x),
        2#0_11110_01100#  => (RA, RB, XS,   INSN_stxvd2x),
        2#0_11101_01100#  => (RA, RB, XS,   INSN_stxvh8x),
        2#0_11100_01100#  => (RA, RB, XS,   INSN_stxvw4x),
        2#0_01100_01100#  => (RA, RB, XSE,  INSN_stxvx),
        2#0_00100_01101#  => (RA, RB, XSR,  INSN_stxvrbx),
        2#0_00111_01101#  => (RA, RB, XSR,  INSN_stxvrdx),
        2#0_00101_01101#  => (RA, RB, XSR,  INSN_stxvrhx),
        2#0_00110_01101#  => (RA, RB, XSR,  INSN_stxvrwx),
        2#0_01100_01101#  => (RA, RB, XSE,  INSN_stxvl),
        2#0_01101_01101#  => (RA, RB, XSE,  INSN_stxvll),
        2#0_00001_01000#  => (RA, RB, NR,   INSN_subf),
        2#0_10001_01000#  => (RA, RB, NR,   INSN_subf), -- subfo
        2#0_00000_01000#  => (RA, RB, NR,   INSN_subfc),
        2#0_10000_01000#  => (RA, RB, NR,   INSN_subfc), -- subfco
        2#0_00100_01000#  => (RA, RB, NR,   INSN_subfe),
        2#0_10100_01000#  => (RA, RB, NR,   INSN_subfe), -- subfeo
        2#0_00111_01000#  => (RA, NR, NR,   INSN_subfme),
        2#0_10111_01000#  => (RA, NR, NR,   INSN_subfme), -- subfmeo
        2#0_00110_01000#  => (RA, NR, NR,   INSN_subfze),
        2#0_10110_01000#  => (RA, NR, NR,   INSN_subfze), -- subfzeo
        2#0_10010_10110#  => (NR, NR, NR,   INSN_sync),
        2#0_00010_00100#  => (RA, RB, NR,   INSN_td),
        2#0_00000_00100#  => (RA, RB, NR,   INSN_tw),
        2#0_01001_10010#  => (NR, RB, RS,   INSN_tlbie),
        2#0_01000_10010#  => (NR, RB, RS,   INSN_tlbiel),
        2#0_10001_10110#  => (NR, NR, NR,   INSN_tlbsync),
        2#0_00000_11110#  => (NR, NR, NR,   INSN_wait),
        2#0_01001_11100#  => (NR, RB, RS,   INSN_xor),

        -- Major opcode 19
        -- Columns with insn(4) = '1' are all illegal and not mapped here; to
        -- fit into 2048 entries, the columns are remapped so that 16-24 are
        -- stored here as 8-15; in other words the address bits are
        -- 1, insn(10..6), 1, insn(5), insn(3..1)
        -- Columns 16-17 here are opcode 19 columns 0-1
        -- Columns 24-31 here are opcode 19 columns 16-23
        2#1_10000_11000#  => (NR, NR, NR,   INSN_bcctr),
        2#1_00000_11000#  => (NR, NR, NR,   INSN_bclr),
        2#1_10001_11000#  => (NR, NR, NR,   INSN_bctar),
        2#1_01000_10001#  => (NR, NR, NR,   INSN_crand),
        2#1_00100_10001#  => (NR, NR, NR,   INSN_crandc),
        2#1_01001_10001#  => (NR, NR, NR,   INSN_creqv),
        2#1_00111_10001#  => (NR, NR, NR,   INSN_crnand),
        2#1_00001_10001#  => (NR, NR, NR,   INSN_crnor),
        2#1_01110_10001#  => (NR, NR, NR,   INSN_cror),
        2#1_01101_10001#  => (NR, NR, NR,   INSN_crorc),
        2#1_00110_10001#  => (NR, NR, NR,   INSN_crxor),
        2#1_00100_11110#  => (NR, NR, NR,   INSN_isync),
        2#1_00000_10000#  => (NR, NR, NR,   INSN_mcrf),
        2#1_00000_11010#  => (NR, NR, NR,   INSN_rfid),
        2#1_00010_11010#  => (NR, NR, NR,   INSN_rfscv),
        2#1_01000_11010#  => (NR, NR, NR,   INSN_rfid), -- hrfid

        -- Major opcode 59
        -- Address bits are 1, insn(10..6), 1, 0, insn(3..1)
        -- Only column 14 is valid here; columns 16-31 are handled in the major table
        -- Column 14 is mapped to column 22.
        -- Columns 20-23 here are opcode 59 columns 12-15
        2#1_11010_10110#  => (NR, FB, NR,   INSN_fcfids),
        2#1_11110_10110#  => (NR, FB, NR,   INSN_fcfidus),

        -- Major opcode 63
        -- Columns 0-15 are mapped here; columns 16-31 are in the major table.
        -- Address bits are 1, insn(10:6), 0, insn(4:1)
        -- Columns 0-15 here are opcode 63 columns 0-15
        2#1_00000_00000#  => (FA, FB, NR,   INSN_fcmpu),
        2#1_00001_00000#  => (FA, FB, NR,   INSN_fcmpo),
        2#1_00010_00000#  => (NR, NR, NR,   INSN_mcrfs),
        2#1_00100_00000#  => (FA, FB, NR,   INSN_ftdiv),
        2#1_00101_00000#  => (NR, FB, NR,   INSN_ftsqrt),
        2#1_00001_00110#  => (NR, NR, NR,   INSN_mtfsb),
        2#1_00010_00110#  => (NR, NR, NR,   INSN_mtfsb),
        2#1_00100_00110#  => (NR, NR, NR,   INSN_mtfsfi),
        2#1_11010_00110#  => (FA, FB, NR,   INSN_fmrgow),
        2#1_11110_00110#  => (FA, FB, NR,   INSN_fmrgew),
        2#1_10010_00111#  => (NR, FB, NR,   INSN_mffs),
        2#1_10110_00111#  => (NR, FB, NR,   INSN_mtfsf),
        2#1_00000_01000#  => (FA, FB, NR,   INSN_fcpsgn),
        2#1_00001_01000#  => (NR, FB, NR,   INSN_fneg),
        2#1_00010_01000#  => (NR, FB, NR,   INSN_fmr),
        2#1_00100_01000#  => (NR, FB, NR,   INSN_fnabs),
        2#1_01000_01000#  => (NR, FB, NR,   INSN_fabs),
        2#1_01100_01000#  => (NR, FB, NR,   INSN_frin),
        2#1_01101_01000#  => (NR, FB, NR,   INSN_friz),
        2#1_01110_01000#  => (NR, FB, NR,   INSN_frip),
        2#1_01111_01000#  => (NR, FB, NR,   INSN_frim),
        2#1_00000_01100#  => (NR, FB, NR,   INSN_frsp),
        2#1_00000_01110#  => (NR, FB, NR,   INSN_fctiw),
        2#1_00100_01110#  => (NR, FB, NR,   INSN_fctiwu),
        2#1_11001_01110#  => (NR, FB, NR,   INSN_fctid),
        2#1_11010_01110#  => (NR, FB, NR,   INSN_fcfid),
        2#1_11101_01110#  => (NR, FB, NR,   INSN_fctidu),
        2#1_11110_01110#  => (NR, FB, NR,   INSN_fcfidu),
        2#1_00000_01111#  => (NR, FB, NR,   INSN_fctiwz),
        2#1_00100_01111#  => (NR, FB, NR,   INSN_fctiwuz),
        2#1_11001_01111#  => (NR, FB, NR,   INSN_fctidz),
        2#1_11101_01111#  => (NR, FB, NR,   INSN_fctiduz),

        others            => (NR, NR, NR,   INSN_illegal)
        );

    type suffix_decode_rom_t is array(0 to 63) of predec_insn;

    constant mls_suffix_rom : suffix_decode_rom_t := (
        14     => (RA, NR, NR,   INSN_paddi),
        32     => (RA, NR, NR,   INSN_plwz),
        34     => (RA, NR, NR,   INSN_plbz),
        36     => (RA, NR, RS,   INSN_pstw),
        38     => (RA, NR, RS,   INSN_pstb),
        40     => (RA, NR, NR,   INSN_plhz),
        42     => (RA, NR, NR,   INSN_plha),
        44     => (RA, NR, RS,   INSN_psth),
        48     => (RA, NR, NR,   INSN_plfs),
        50     => (RA, NR, NR,   INSN_plfd),
        52     => (RA, NR, FRS,  INSN_pstfs),
        54     => (RA, NR, FRS,  INSN_pstfd),
        others => (NR, NR, NR,   INSN_illegal)
        );

    constant eightls_suffix_rom : suffix_decode_rom_t := (
        41     => (RA, NR, NR,   INSN_plwa),
        42     => (RA, NR, NR,   INSN_plxsd),
        43     => (RA, NR, NR,   INSN_plxssp),
        46     => (RA, NR, VRS,  INSN_pstxsd),
        47     => (RA, NR, VRS,  INSN_pstxssp),
        50     => (RA, NR, NR,   INSN_plxv),
        51     => (RA, NR, NR,   INSN_plxv),
        54     => (RA, NR, FRSE, INSN_pstxv_fp),
        55     => (RA, NR, VRSE, INSN_pstxv_vec),
        56     => (RA, NR, NR,   INSN_plq),
        57     => (RA, NR, NR,   INSN_pld),
        60     => (RA, NR, RS,   INSN_pstq),
        61     => (RA, NR, RS,   INSN_pstd),
        others => (NR, NR, NR,   INSN_illegal)
        );

    -- Primary opcode 4, columns 0 to 15 (where the column index is
    -- bits 5:0 of the instruction) contains vector instructions.
    -- This is indexed by bits 10:6 and 3:0.
    type vector_predecode_rom_t is array(0 to 511) of predec_insn;
    constant vector_predecode_rom : vector_predecode_rom_t := (
        2#10000_0100# => (NR, VB, VRA, INSN_vand),      -- VRA comes in through C port
        2#10001_0100# => (NR, VB, VRA, INSN_vandc),     -- because integer logical ops
        2#10010_0100# => (NR, VB, VRA, INSN_vor),       -- use RS, RB
        2#10011_0100# => (NR, VB, VRA, INSN_vxor),
        2#10100_0100# => (NR, VB, VRA, INSN_vnor),
        2#10101_0100# => (NR, VB, VRA, INSN_vorc),
        2#10110_0100# => (NR, VB, VRA, INSN_vnand),
        2#11010_0100# => (NR, VB, VRA, INSN_veqv),
        others        => (NR, NR, NR,  INSN_vemu)
        );

    -- Primary opcode 60, columns 0 to 30 by 2 (column index
    -- is bits 5:1 of the instruction), indexed by bits 10:2
    type vsx_predecode_rom_t is array(0 to 511) of predec_insn;
    constant vsx_predecode_rom : vsx_predecode_rom_t := (
        2#10000_0100# to 2#10000_0101# => (NR, XB, XA, INSN_xxland),    -- XA comes in through C port
        2#10001_0100# to 2#10001_0101# => (NR, XB, XA, INSN_xxlandc),   -- because integer logical ops
        2#10010_0100# to 2#10010_0101# => (NR, XB, XA, INSN_xxlor),     -- use RS, RB
        2#10011_0100# to 2#10011_0101# => (NR, XB, XA, INSN_xxlxor),
        2#10100_0100# to 2#10100_0101# => (NR, XB, XA, INSN_xxlnor),
        2#10101_0100# to 2#10101_0101# => (NR, XB, XA, INSN_xxlorc),
        2#10110_0100# to 2#10110_0101# => (NR, XB, XA, INSN_xxlnand),
        2#10111_0100# to 2#10111_0101# => (NR, XB, XA, INSN_xxleqv),
        others                         => (NR, NR, NR, INSN_xemu)
        );

    constant IOUT_LEN : natural := ICODE_LEN + IMAGE_LEN;

    type predec_t is record
        image         : std_ulogic_vector(31 downto 0);
        maj_predecode : predec_insn;
        row_predecode : predec_insn;
        vec_predecode : predec_insn;
        vsx_predecode : predec_insn;
    end record;

    subtype index_t is integer range 0 to WIDTH-1;
    type predec_array is array(index_t) of predec_t;

    signal pred : predec_array;
    signal valid : std_ulogic;
    signal valid_1 : std_ulogic;
    signal index : unsigned(ROWBITS-1 downto 0);
    signal be : std_ulogic;

    signal rowcounter : unsigned(ROWBITS-1 downto 0);
    signal first_insn : std_ulogic_vector(31 downto 0);

    type predec_2_t is record
        image : std_ulogic_vector(31 downto 0);
        icode : predec_insn;
        class : std_ulogic_vector(2 downto 0);
    end record;

    type predec_2_array is array(index_t) of predec_2_t;

    signal pre2   : predec_2_array;
    signal pre2in : predec_2_array;
    signal be_1   : std_ulogic;

begin
    predecode_0: process(clk)
        variable majaddr  : std_ulogic_vector(10 downto 0);
        variable rowaddr  : std_ulogic_vector(10 downto 0);
        variable vecaddr  : std_ulogic_vector(8 downto 0);
        variable vsxaddr  : std_ulogic_vector(8 downto 0);
        variable iword    : std_ulogic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                valid <= '0';
                rowcounter <= to_unsigned(0, ROWBITS);
                index <= to_unsigned(0, ROWBITS);
                for i in index_t loop
                    pred(i).image <= (others => '0');
                    pred(i).maj_predecode <= no_insn;
                    pred(i).row_predecode <= no_insn;
                end loop;
                first_insn <= (others => '0');
                be <= '0';

            elsif valid_in = '1' then
                valid <= '1';
                index <= insn_index;
                be <= big_endian;
                if first_row = '1' then
                    rowcounter <= to_unsigned(0, ROWBITS);
                    first_insn <= insns_in(31 downto 0);
                else
                    rowcounter <= rowcounter + 1;
                end if;
                for i in index_t loop
                    iword := insns_in(i * 32 + 31 downto i * 32);
                    pred(i).image <= iword;

                    if is_X(iword) then
                        pred(i).maj_predecode <= no_insn;
                        pred(i).row_predecode <= no_insn;
                    else
                        majaddr := iword(31 downto 26) & iword(4 downto 0);

                        -- row_predecode_rom is used for op 19, 31, 59, 63
                        -- addr bit 10 is 0 for op 31, 1 for 19, 59, 63
                        rowaddr(10) := iword(31) or not iword(29);
                        rowaddr(9 downto 5) := iword(10 downto 6);
                        if iword(28) = '0' then
                            -- op 19 and op 59
                            rowaddr(4 downto 3) := '1' & iword(5);
                        else
                            -- op 31 and 63; for 63 we only use this when iword(5) = '0'
                            rowaddr(4 downto 3) := iword(5 downto 4);
                        end if;
                        rowaddr(2 downto 0) := iword(3 downto 1);

                        -- vector_predecode_rom is used for primary opcode 4
                        vecaddr := iword(10 downto 6) & iword(3 downto 0);

                        -- vsx_predecode_rom is used for primary opcode 60
                        vsxaddr := iword(10 downto 6) & iword(5 downto 2);

                        pred(i).maj_predecode <= major_predecode_rom(to_integer(unsigned(majaddr)));
                        pred(i).row_predecode <= row_predecode_rom(to_integer(unsigned(rowaddr)));
                        pred(i).vec_predecode <= vector_predecode_rom(to_integer(unsigned(vecaddr)));
                        pred(i).vsx_predecode <= vsx_predecode_rom(to_integer(unsigned(vsxaddr)));
                    end if;
                end loop;

            elsif valid_1 = '1' then
                valid <= '0';
            end if;
        end if;
    end process;

    predecode_1: process(all)
        variable iword    : std_ulogic_vector(31 downto 0);
        variable use_row  : std_ulogic;
        variable illegal  : std_ulogic;
        variable use_pref : std_ulogic;
        variable use_vec  : std_ulogic;
        variable use_vsx  : std_ulogic;
        variable icode    : predec_insn;
        variable ovalid   : std_ulogic;
        variable suffix   : std_ulogic_vector(5 downto 0);
        variable class    : std_ulogic_vector(2 downto 0);
    begin
        ovalid := valid;
        for i in index_t loop
            iword := pred(i).image;
            icode := pred(i).maj_predecode;
            use_row := '0';
            use_vec := '0';
            use_vsx := '0';
            illegal := '0';
            use_pref := '0';
            suffix := (others => '0');
            class := iclass_normal;

            case iword(31 downto 26) is
                when "000001" => -- 1
                    -- prefix opcode, try to locate the suffix word
                    use_pref := valid;
                    class := iclass_prefixed;
                    if i = WIDTH - 1 then
                        if index = to_unsigned(2**ROWBITS - 1, ROWBITS) then
                            -- prefix is at an address equal to 60 mod 64, i.e. misaligned
                            use_pref := '0';
                            class := iclass_misaligned_prefix;
                        end if;
                        if rowcounter = to_unsigned(2**ROWBITS - 1, ROWBITS) then
                            -- last element in last row to be received,
                            -- suffix is in first_insn
                            suffix := first_insn(31 downto 26);
                        else
                            -- suffix is in next doubleword from memory
                            suffix := insns_in(31 downto 26);
                            if valid_in = '0' then
                                -- still waiting for the next dword
                                ovalid := '0';
                                use_pref := '0';
                            end if;
                        end if;
                    else
                        -- suffix is in the next word to the left
                        suffix := pred(i+1).image(31 downto 26);
                    end if;
                    -- examine type field of prefix
                    if use_pref = '1' then
                        if iword(25 downto 23) = "000" then
                            -- 8LS format
                            icode := eightls_suffix_rom(to_integer(unsigned(suffix)));
                        elsif iword(25 downto 23) = "100" then
                            -- MLS format
                            icode := mls_suffix_rom(to_integer(unsigned(suffix)));
                        elsif iword(25 downto 20) = "110000" then
                            -- pnop
                            icode := (NR, NR, NR, INSN_pnop);
                        else
                            illegal := '1';
                        end if;
                    end if;

                when "000100" => -- 4
                    -- major opcode 4, mostly VMX/VSX stuff but also some integer ops (madd*)
                    -- 64 columns indexed by bits 5..0; columns 32..63 are in major table
                    -- Columns 0..15 are in vector table, 16..31 are not currently decoded
                    if iword(5) = '0' then
                        use_vec := '1';
                        illegal := iword(4);
                    end if;

                when "010000" => -- 16
                    class := iclass_direct_br_cond;

                when "010010" => -- 18
                    class := iclass_direct_br_uncond;

                when "010011" => -- 19
                    -- Columns 8-15 and 24-31 don't have any valid instructions
                    -- (where insn(5..1) is the column number).
                    -- addpcis (column 2) is in the major table
                    -- Other valid columns are mapped to columns in the second
                    -- half of the row table: columns 0-1 are mapped to 16-17
                    -- and 16-23 are mapped to 24-31.
                    illegal := iword(4);
                    use_row := iword(5) or (not iword(3) and not iword(2));

                when "011000" => -- 24
                    -- ori, special-case the standard NOP
                    if std_match(iword, "01100000000000000000000000000000") then
                        icode := (NR, NR, NR, INSN_nop);
                    end if;

                when "011111" => -- 31
                    -- major opcode 31, lots of things
                    -- Use the first half of the row table for all columns
                    use_row := '1';

                when "111011" => -- 59
                    -- floating point operations, mostly single-precision
                    -- Columns 0-11 are illegal; columns 12-15 are mapped
                    -- to columns 20-23 in the second half of the row table,
                    -- and columns 16-31 are in the major table.
                    illegal := not iword(5) and (not iword(4) or not iword(3));
                    use_row := not iword(5);

                when "111100" => -- 60
                    -- VSX instructions
                    -- The XPND060 tables are not handled as yet.
                    use_vsx := '1';

                when "111111" => -- 63
                    -- floating point operations, general and double-precision
                    -- Use columns 0-15 of the second half of the row table
                    -- for columns 0-15, and the major table for columns 16-31.
                    use_row := not iword(5);

                when others =>
            end case;
            if use_row = '1' then
                icode := pred(i).row_predecode;
            elsif use_vec = '1' then
                icode := pred(i).vec_predecode;
            elsif use_vsx = '1' then
                icode := pred(i).vsx_predecode;
            end if;

            -- Mark FP instructions as illegal if we don't have an FPU
            if not HAS_FPU and icode.insn >= INSN_first_frs then
                illegal := '1';
            end if;
            -- Mark vector instructions as illegal if we don't have a vector unit
            if not HAS_VECVSX and icode.insn >= INSN_first_vrs then
                illegal := '1';
            end if;
            if icode.insn = INSN_illegal then
                illegal := '1';
            end if;

            if rst = '0' then
                pre2in(i).image <= iword;
                pre2in(i).icode <= icode;
                if valid = '0' or illegal = '1' then
                    pre2in(i).class <= iclass_illegal;
                else
                    pre2in(i).class <= class;
                end if;
            else
                pre2in(i).image <= (others => '0');
                pre2in(i).icode <= no_insn;
                pre2in(i).class <= "000";
            end if;

        end loop;
        valid_1 <= ovalid and not rst;
    end process;

    predecode_2: process(clk)
    begin
        if rising_edge(clk) then
            pre2 <= pre2in;
            be_1 <= be and not rst;
            valid_out <= valid_1;
        end if;
    end process;

    -- After second clock edge, do prefix handling
    -- and translate register access information
    predecode_3: process(clk)
        variable iword    : std_ulogic_vector(31 downto 0);
        variable icode    : predec_insn;
        variable ici      : std_ulogic_vector(IOUT_LEN - 1 downto 0);
        variable iregs    : std_ulogic_vector(8 downto 0);
        variable class    : std_ulogic_vector(2 downto 0);
    begin
        for i in index_t loop
            iword := pre2(i).image;
            icode := pre2(i).icode;
            class := pre2(i).class;
            
            -- Decode register specifiers
            iregs := 9x"000";
            case icode.areg is
                when NR =>
                when RA =>
                    iregs(7) := '1';
                when FA =>
                    iregs(8) := '1';
                when VA =>
                    iregs(7) := '1';
                    iregs(8) := '1';
                when XA =>
                    iregs(7) := '1';
                    iregs(8) := iword(2);
            end case;
            case icode.breg is
                when NR =>
                when RB =>
                    iregs(5) := '1';
                when FB =>
                    iregs(6) := '1';
                when VB =>
                    iregs(5) := '1';
                    iregs(6) := '1';
                when XB =>
                    iregs(5) := '1';
                    iregs(6) := iword(1);
            end case;
            case icode.creg is
                when NR =>
                when RC =>
                    iregs(1) := '1';
                when FRC =>
                    iregs(1) := '1';
                    iregs(3) := '1';
                when VRC =>
                    iregs(1) := '1';
                    iregs(4) := '1';
                when RS =>
                when RSE =>
                    iregs(0) := not be_1;
                when FRS =>
                    iregs(3) := '1';
                when FRSE =>
                    iregs(3) := '1';
                    iregs(2) := not be_1;
                when VRS =>
                    iregs(4) := '1';
                when VRSE =>
                    iregs(4) := '1';
                    iregs(2) := not be_1;
                when VRA =>
                    iregs(1 downto 0) := "11";
                    iregs(4) := '1';
                when XS =>
                    iregs(3) := not iword(0);
                    iregs(4) := iword(0);
                when XSE =>
                    iregs(2) := not be_1;
                    iregs(3) := not iword(0);
                    iregs(4) := iword(0);
                when XSR =>
                    iregs(2) := '1';
                    iregs(3) := not iword(0);
                    iregs(4) := iword(0);
                when XC =>
                    iregs(1) := '1';
                    iregs(3) := not iword(3);
                    iregs(4) := iword(3);
                when XA =>
                    iregs(1 downto 0) := "11";
                    iregs(3) := not iword(2);
                    iregs(4) := iword(2);
            end case;

            -- Assemble 48-bit predecoded instruction word
            ici(31 downto 0) := iword;
            ici(IOUT_LEN - 1 downto 32) := (others => '0');
            if class /= iclass_illegal then
                ici(IMAGE_LEN + 8 downto IMAGE_LEN) :=
                    std_ulogic_vector(to_unsigned(insn_code'pos(icode.insn), 9));
                ici(IMAGE_LEN + 18 downto IMAGE_LEN + 10) := iregs;
                ici(IMAGE_LEN + 21 downto IMAGE_LEN + 19) := class;
            end if;
            icodes_out(i * IOUT_LEN + IOUT_LEN - 1 downto i * IOUT_LEN) <= ici;
        end loop;
    end process;

end architecture behaviour;
