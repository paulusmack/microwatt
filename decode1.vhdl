library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.common.all;
use work.decode_types.all;

entity decode1 is
    generic (
        HAS_FPU : boolean := true;
        -- Non-zero to enable log data collection
        LOG_LENGTH : natural := 0
        );
    port (
        clk       : in std_ulogic;
        rst       : in std_ulogic;

        stall_in  : in  std_ulogic;
        flush_in  : in  std_ulogic;
        busy_out  : out std_ulogic;
        flush_out : out std_ulogic;

        f_in      : in IcacheToDecode1Type;
        f_out     : out Decode1ToFetch1Type;
        d_out     : out Decode1ToDecode2Type;
        log_out   : out std_ulogic_vector(12 downto 0)
	);
end entity decode1;

architecture behaviour of decode1 is
    signal r, rin : Decode1ToDecode2Type;
    signal s      : Decode1ToDecode2Type;
    signal f, fin : Decode1ToFetch1Type;

    constant illegal_inst : decode_rom_t :=
        (NONE, NONE, OP_ILLEGAL,   NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE);

    type reg_internal_t is record
        maj_decode : decode_rom_t;
        row_decode : decode_rom_t;
        use_row  : std_ulogic;
        override : std_ulogic;
        override_decode: decode_rom_t;
        override_unit: std_ulogic;
        force_single: std_ulogic;
    end record;
    constant reg_internal_t_init : reg_internal_t :=
        (maj_decode => illegal_inst, row_decode => illegal_inst, use_row => '0',
         override => '0', override_decode => illegal_inst, override_unit => '0', force_single => '0');

    signal ri, ri_in : reg_internal_t;
    signal si        : reg_internal_t;

    type br_predictor_t is record
        br_nia    : std_ulogic_vector(61 downto 0);
        br_offset : signed(23 downto 0);
        predict   : std_ulogic;
    end record;

    signal br, br_in : br_predictor_t;

    type decoder_rom_t is array(0 to 2047) of decode_rom_t;

    -- Indexed by bits 31-26 (major opcode) and 4-0 of instruction word
    signal major_decode_rom : decoder_rom_t := (
        --                                     unit   fac   internal      in1         in2          in3   out   CR   CR   inv  inv  cry   cry  ldst  BR   sgn  upd  rsrv 32b  sgn  rc    lk   sgl  rpt
        --                                                       op                                            in   out   A   out  in    out  len        ext                                 pipe
        2#001100_00000# to 2#001100_11111# =>  (ALU,  NONE, OP_ADD,       RA,         CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '1', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- addic
        2#001101_00000# to 2#001101_11111# =>  (ALU,  NONE, OP_ADD,       RA,         CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '1', NONE, '0', '0', '0', '0', '0', '0', ONE,  '0', '0', NONE), -- addic.
        2#001110_00000# to 2#001110_11111# =>  (ALU,  NONE, OP_ADD,       RA_OR_ZERO, CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- addi
        2#001111_00000# to 2#001111_11111# =>  (ALU,  NONE, OP_ADD,       RA_OR_ZERO, CONST_SI_HI, NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- addis
        2#010011_00100# to 2#010011_00101# =>  (ALU,  NONE, OP_ADD,       CIA,        CONST_DXHI4, NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addpcis
        2#011100_00000# to 2#011100_11111# =>  (ALU,  NONE, OP_AND,       NONE,       CONST_UI,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', ONE,  '0', '0', NONE), -- andi.
        2#011101_00000# to 2#011101_11111# =>  (ALU,  NONE, OP_AND,       NONE,       CONST_UI_HI, RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', ONE,  '0', '0', NONE), -- andis.
        2#000000_00000# to 2#000000_11111# =>  (ALU,  NONE, OP_ATTN,      NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- attn
        2#010010_00000# to 2#010010_11111# =>  (ALU,  NONE, OP_B,         NONE,       CONST_LI,    NONE, SPR,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '1', '0', NONE), -- b
        2#010000_00000# to 2#010000_11111# =>  (ALU,  NONE, OP_BC,        SPR,        CONST_BD,    NONE, SPR , '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '1', '0', NONE), -- bc
        2#001011_00000# to 2#001011_11111# =>  (ALU,  NONE, OP_CMP,       RA,         CONST_SI,    NONE, NONE, '0', '1', '1', '0', ONE,  '0', NONE, '0', '0', '0', '0', '0', '1', NONE, '0', '0', NONE), -- cmpi
        2#001010_00000# to 2#001010_11111# =>  (ALU,  NONE, OP_CMP,       RA,         CONST_UI,    NONE, NONE, '0', '1', '1', '0', ONE,  '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- cmpli
        2#111011_00100# to 2#111011_00101# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fdivs
        2#111011_01000# to 2#111011_01001# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fsubs
        2#111011_01010# to 2#111011_01011# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fadds
        2#111011_01100# to 2#111011_01101# =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fsqrts
        2#111011_10000# to 2#111011_10001# =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fres
        2#111011_10010# to 2#111011_10011# =>  (FPU,  FPU,  OP_FPOP,      FRA,        NONE,        FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fmuls
        2#111011_10100# to 2#111011_10101# =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- frsqrtes
        2#111011_11000# to 2#111011_11001# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fmsubs
        2#111011_11010# to 2#111011_11011# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fmadds
        2#111011_11100# to 2#111011_11101# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fnmsubs
        2#111011_11110# to 2#111011_11111# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fnmadds
        2#111111_00100# to 2#111111_00101# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fdiv
        2#111111_01000# to 2#111111_01001# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fsub
        2#111111_01010# to 2#111111_01011# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fadd
        2#111111_01100# to 2#111111_01101# =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fsqrt
        2#111111_01110# to 2#111111_01111# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fsel
        2#111111_10000# to 2#111111_10001# =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fre
        2#111111_10010# to 2#111111_10011# =>  (FPU,  FPU,  OP_FPOP,      FRA,        NONE,        FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fmul
        2#111111_10100# to 2#111111_10101# =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- frsqrte
        2#111111_11000# to 2#111111_11001# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fmsub
        2#111111_11010# to 2#111111_11011# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fmadd
        2#111111_11100# to 2#111111_11101# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fnmsub
        2#111111_11110# to 2#111111_11111# =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         FRC,  FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- fnmadd
        2#100010_00000# to 2#100010_11111# =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lbz
        2#100011_00000# to 2#100011_11111# =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lbzu
        2#111010_00000#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ld
        2#111010_00100#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ld
        2#111010_01000#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ld
        2#111010_01100#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ld
        2#111010_10000#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ld
        2#111010_10100#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ld
        2#111010_11000#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ld
        2#111010_11100#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ld
        2#111010_00001#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- ldu
        2#111010_00101#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- ldu
        2#111010_01001#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- ldu
        2#111010_01101#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- ldu
        2#111010_10001#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- ldu
        2#111010_10101#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- ldu
        2#111010_11001#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- ldu
        2#111010_11101#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- ldu
        2#110010_00000# to 2#110010_11111# =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lfd
        2#110011_00000# to 2#110011_11111# =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lfdu
        2#110000_00000# to 2#110000_11111# =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '1', '0', NONE, '0', '0', NONE), -- lfs
        2#110001_00000# to 2#110001_11111# =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '1', '0', '1', '0', NONE, '0', '0', DUPD), -- lfsu
        2#101010_00000# to 2#101010_11111# =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lha
        2#101011_00000# to 2#101011_11111# =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '1', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lhau
        2#101000_00000# to 2#101000_11111# =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lhz
        2#101001_00000# to 2#101001_11111# =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lhzu
        2#111000_00000# to 2#111000_11111# =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DQ,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', DRTE), -- lq
        2#111010_00010#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwa
        2#111010_00110#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwa
        2#111010_01010#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwa
        2#111010_01110#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwa
        2#111010_10010#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwa
        2#111010_10110#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwa
        2#111010_11010#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwa
        2#111010_11110#                    =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_DS,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwa
        2#100000_00000# to 2#100000_11111# =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwz
        2#100001_00000# to 2#100001_11111# =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lwzu
        2#000100_10000#                    =>  (ALU,  NONE, OP_MUL_H64,   RA,         RB,          RCR,  RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- maddhd
        2#000100_10001#                    =>  (ALU,  NONE, OP_MUL_H64,   RA,         RB,          RCR,  RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- maddhdu
        2#000100_10011#                    =>  (ALU,  NONE, OP_MUL_L64,   RA,         RB,          RCR,  RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- maddld
        2#000111_00000# to 2#000111_11111# =>  (ALU,  NONE, OP_MUL_L64,   RA,         CONST_SI,    NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', NONE, '0', '0', NONE), -- mulli
        2#011000_00000# to 2#011000_11111# =>  (ALU,  NONE, OP_OR,        NONE,       CONST_UI,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ori
        2#011001_00000# to 2#011001_11111# =>  (ALU,  NONE, OP_OR,        NONE,       CONST_UI_HI, RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- oris
        2#011110_01000# to 2#011110_01001# =>  (ALU,  NONE, OP_RLC,       NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldic
        2#011110_01010# to 2#011110_01011# =>  (ALU,  NONE, OP_RLC,       NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldic
        2#011110_00000# to 2#011110_00001# =>  (ALU,  NONE, OP_RLCL,      NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldicl
        2#011110_00010# to 2#011110_00011# =>  (ALU,  NONE, OP_RLCL,      NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldicl
        2#011110_00100# to 2#011110_00101# =>  (ALU,  NONE, OP_RLCR,      NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldicr
        2#011110_00110# to 2#011110_00111# =>  (ALU,  NONE, OP_RLCR,      NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldicr
        2#011110_01100# to 2#011110_01101# =>  (ALU,  NONE, OP_RLC,       RA,         CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldimi
        2#011110_01110# to 2#011110_01111# =>  (ALU,  NONE, OP_RLC,       RA,         CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldimi
        2#011110_10000# to 2#011110_10001# =>  (ALU,  NONE, OP_RLCL,      NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldcl
        2#011110_10010# to 2#011110_10011# =>  (ALU,  NONE, OP_RLCR,      NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- rldcr
        2#010100_00000# to 2#010100_11111# =>  (ALU,  NONE, OP_RLC,       RA,         CONST_SH32,  RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- rlwimi
        2#010101_00000# to 2#010101_11111# =>  (ALU,  NONE, OP_RLC,       NONE,       CONST_SH32,  RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- rlwinm
        2#010111_00000# to 2#010111_11111# =>  (ALU,  NONE, OP_RLC,       NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- rlwnm
        2#010001_00000# to 2#010001_11111# =>  (ALU,  NONE, OP_SC,        NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- sc
        2#100110_00000# to 2#100110_11111# =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_SI,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stb
        2#100111_00000# to 2#100111_11111# =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_SI,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stbu
        2#111110_00000#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- std
        2#111110_00100#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- std
        2#111110_01000#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- std
        2#111110_01100#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- std
        2#111110_10000#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- std
        2#111110_10100#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- std
        2#111110_11000#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- std
        2#111110_11100#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- std
        2#111110_00001#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stdu
        2#111110_00101#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stdu
        2#111110_01001#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stdu
        2#111110_01101#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stdu
        2#111110_10001#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stdu
        2#111110_10101#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stdu
        2#111110_11001#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stdu
        2#111110_11101#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stdu
        2#110110_00000# to 2#110110_11111# =>  (LDST, FPU,  OP_STORE,     RA_OR_ZERO, CONST_SI,    FRS,  NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stfd
        2#110111_00000# to 2#110111_11111# =>  (LDST, FPU,  OP_STORE,     RA_OR_ZERO, CONST_SI,    FRS,  RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stfdu
        2#110100_00000# to 2#110100_11111# =>  (LDST, FPU,  OP_STORE,     RA_OR_ZERO, CONST_SI,    FRS,  NONE, '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '1', '0', NONE, '0', '0', NONE), -- stfs
        2#110101_00000# to 2#110101_11111# =>  (LDST, FPU,  OP_STORE,     RA_OR_ZERO, CONST_SI,    FRS,  RA,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '1', '0', '1', '0', NONE, '0', '0', NONE), -- stfsu
        2#101100_00000# to 2#101100_11111# =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_SI,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- sth
        2#101101_00000# to 2#101101_11111# =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_SI,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- sthu
        2#111110_00010#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', DRSE), -- stq
        2#111110_00110#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', DRSE), -- stq
        2#111110_01010#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', DRSE), -- stq
        2#111110_01110#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', DRSE), -- stq
        2#111110_10010#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', DRSE), -- stq
        2#111110_10110#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', DRSE), -- stq
        2#111110_11010#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', DRSE), -- stq
        2#111110_11110#                    =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_DS,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', DRSE), -- stq
        2#100100_00000# to 2#100100_11111# =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_SI,    RS,   NONE, '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stw
        2#100101_00000# to 2#100101_11111# =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, CONST_SI,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stwu
        2#001000_00000# to 2#001000_11111# =>  (ALU,  NONE, OP_ADD,       RA,         CONST_SI,    NONE, RT,   '0', '0', '1', '0', ONE,  '1', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- subfic
        2#000010_00000# to 2#000010_11111# =>  (ALU,  NONE, OP_TRAP,      RA,         CONST_SI,    NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- tdi
        2#000011_00000# to 2#000011_11111# =>  (ALU,  NONE, OP_TRAP,      RA,         CONST_SI,    NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', NONE, '0', '1', NONE), -- twi
        2#011010_00000# to 2#011010_11111# =>  (ALU,  NONE, OP_XOR,       NONE,       CONST_UI,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- xori
        2#011011_00000# to 2#011011_11111# =>  (ALU,  NONE, OP_XOR,       NONE,       CONST_UI_HI, RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- xoris
        others   => illegal_inst
        );

    -- Note: reformat with column -t -o ' '
    signal row_decode_rom : decoder_rom_t := (
        -- Major opcode 31
        -- Address bits are 0 insn(10:1)
        --                     unit  fac   internal      in1         in2          in3   out   CR   CR   inv  inv  cry   cry  ldst  BR   sgn  upd  rsrv 32b  sgn  rc    lk   sgl  rpt
        --                                      op                                            in   out   A   out  in    out  len        ext                                 pipe
        2#0_01000_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- add
        2#0_11000_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addo
        2#0_00000_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addc
        2#0_10000_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addco
        2#0_00100_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- adde
        2#0_10100_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addeo
        2#0_00101_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', OV,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addex
        2#0_00010_01010#  =>  (ALU,  NONE, OP_ADDG6S,    RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- addg6s
        2#0_00111_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         CONST_M1,    NONE, RT,   '0', '0', '0', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addme
        2#0_10111_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         CONST_M1,    NONE, RT,   '0', '0', '0', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addmeo
        2#0_00110_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         NONE,        NONE, RT,   '0', '0', '0', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addze
        2#0_10110_01010#  =>  (ALU,  NONE, OP_ADD,       RA,         NONE,        NONE, RT,   '0', '0', '0', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- addzeo
        2#0_00000_11100#  =>  (ALU,  NONE, OP_AND,       NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- and
        2#0_00001_11100#  =>  (ALU,  NONE, OP_AND,       NONE,       RB,          RS,   RA,   '0', '0', '1', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- andc
        2#0_00111_11100#  =>  (ALU,  NONE, OP_BPERM,     NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- bperm
        2#0_01001_11010#  =>  (ALU,  NONE, OP_BCD,       NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- cbcdtd
        2#0_01000_11010#  =>  (ALU,  NONE, OP_BCD,       NONE,       NONE,        RS,   RA,   '0', '0', '1', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- cdtbcd
        2#0_00000_00000#  =>  (ALU,  NONE, OP_CMP,       RA,         RB,          NONE, NONE, '0', '1', '1', '0', ONE,  '0', NONE, '0', '0', '0', '0', '0', '1', NONE, '0', '0', NONE), -- cmp
        2#0_01111_11100#  =>  (ALU,  NONE, OP_CMPB,      NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- cmpb
        2#0_00111_00000#  =>  (ALU,  NONE, OP_CMPEQB,    RA,         RB,          NONE, NONE, '0', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- cmpeqb
        2#0_00001_00000#  =>  (ALU,  NONE, OP_CMP,       RA,         RB,          NONE, NONE, '0', '1', '1', '0', ONE,  '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- cmpl
        2#0_00110_00000#  =>  (ALU,  NONE, OP_CMPRB,     RA,         RB,          NONE, NONE, '0', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- cmprb
        2#0_00001_11010#  =>  (ALU,  NONE, OP_CNTZ,      NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- cntlzd
        2#0_00000_11010#  =>  (ALU,  NONE, OP_CNTZ,      NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- cntlzw
        2#0_10001_11010#  =>  (ALU,  NONE, OP_CNTZ,      NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- cnttzd
        2#0_10000_11010#  =>  (ALU,  NONE, OP_CNTZ,      NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- cnttzw
        2#0_10111_10011#  =>  (ALU,  NONE, OP_DARN,      NONE,       NONE,        NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- darn
        2#0_00010_10110#  =>  (ALU,  NONE, OP_DCBF,      NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- dcbf
        2#0_00001_10110#  =>  (ALU,  NONE, OP_DCBST,     NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- dcbst
        2#0_01000_10110#  =>  (ALU,  NONE, OP_DCBT,      NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- dcbt
        2#0_00111_10110#  =>  (ALU,  NONE, OP_DCBTST,    NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- dcbtst
        2#0_11111_10110#  =>  (LDST, NONE, OP_DCBZ,      RA_OR_ZERO, RB,          NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- dcbz
        2#0_01100_01001#  =>  (ALU,  NONE, OP_DIVE,      RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- divdeu
        2#0_11100_01001#  =>  (ALU,  NONE, OP_DIVE,      RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- divdeuo
        2#0_01100_01011#  =>  (ALU,  NONE, OP_DIVE,      RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- divweu
        2#0_11100_01011#  =>  (ALU,  NONE, OP_DIVE,      RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- divweuo
        2#0_01101_01001#  =>  (ALU,  NONE, OP_DIVE,      RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- divde
        2#0_11101_01001#  =>  (ALU,  NONE, OP_DIVE,      RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- divdeo
        2#0_01101_01011#  =>  (ALU,  NONE, OP_DIVE,      RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- divwe
        2#0_11101_01011#  =>  (ALU,  NONE, OP_DIVE,      RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- divweo
        2#0_01110_01001#  =>  (ALU,  NONE, OP_DIV,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- divdu
        2#0_11110_01001#  =>  (ALU,  NONE, OP_DIV,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- divduo
        2#0_01110_01011#  =>  (ALU,  NONE, OP_DIV,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- divwu
        2#0_11110_01011#  =>  (ALU,  NONE, OP_DIV,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- divwuo
        2#0_01111_01001#  =>  (ALU,  NONE, OP_DIV,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- divd
        2#0_11111_01001#  =>  (ALU,  NONE, OP_DIV,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- divdo
        2#0_01111_01011#  =>  (ALU,  NONE, OP_DIV,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- divw
        2#0_11111_01011#  =>  (ALU,  NONE, OP_DIV,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- divwo
        2#0_11001_10110#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- dss
        2#0_01010_10110#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- dst
        2#0_01011_10110#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- dstst
        2#0_11010_10110#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- eieio
        2#0_01000_11100#  =>  (ALU,  NONE, OP_XOR,       NONE,       RB,          RS,   RA,   '0', '0', '0', '1', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- eqv
        2#0_11101_11010#  =>  (ALU,  NONE, OP_EXTS,      NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- extsb
        2#0_11100_11010#  =>  (ALU,  NONE, OP_EXTS,      NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- extsh
        2#0_11110_11010#  =>  (ALU,  NONE, OP_EXTS,      NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- extsw
        2#0_11011_11010#  =>  (ALU,  NONE, OP_EXTSWSLI,  NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- extswsli
        2#0_11011_11011#  =>  (ALU,  NONE, OP_EXTSWSLI,  NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- extswsli
        2#0_11110_10110#  =>  (ALU,  NONE, OP_ICBI,      NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- icbi
        2#0_00000_10110#  =>  (ALU,  NONE, OP_ICBT,      NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- icbt
        2#0_00000_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- isel
        2#0_00001_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_00010_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_00011_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_00100_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_00101_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_00110_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_00111_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_01000_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_01001_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_01010_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_01011_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_01100_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_01101_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_01110_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_01111_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_10000_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_10001_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_10010_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_10011_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_10100_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_10101_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_10110_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_10111_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_11000_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_11001_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_11010_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_11011_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_11100_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_11101_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_11110_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_11111_01111#  =>  (ALU,  NONE, OP_ISEL,      RA_OR_ZERO, RB,          NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- isel
        2#0_00001_10100#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '1', '0', '0', NONE, '0', '0', NONE), -- lbarx
        2#0_11010_10101#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lbzcix
        2#0_00011_10111#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lbzux
        2#0_00010_10111#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lbzx
        2#0_00010_10100#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '1', '0', '0', NONE, '0', '0', NONE), -- ldarx
        2#0_10000_10100#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '1', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ldbrx
        2#0_11011_10101#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ldcix
        2#0_00001_10101#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- ldux
        2#0_00000_10101#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- ldx
        2#0_10010_10111#  =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, RB,          NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lfdx
        2#0_10011_10111#  =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, RB,          NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lfdux
        2#0_11010_10111#  =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, RB,          NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lfiwax
        2#0_11011_10111#  =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, RB,          NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lfiwzx
        2#0_10000_10111#  =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, RB,          NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '1', '0', NONE, '0', '0', NONE), -- lfsx
        2#0_10001_10111#  =>  (LDST, FPU,  OP_LOAD,      RA_OR_ZERO, RB,          NONE, FRT,  '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '1', '0', '1', '0', NONE, '0', '0', DUPD), -- lfsux
        2#0_00011_10100#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '0', '1', '0', '0', NONE, '0', '0', NONE), -- lharx
        2#0_01011_10111#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '1', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lhaux
        2#0_01010_10111#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lhax
        2#0_11000_10110#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '1', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lhbrx
        2#0_11001_10101#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lhzcix
        2#0_01001_10111#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lhzux
        2#0_01000_10111#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lhzx
        2#0_01000_10100#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '1', '0', '0', NONE, '0', '0', DRTE), -- lqarx
        2#0_00000_10100#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '1', '0', '0', NONE, '0', '0', NONE), -- lwarx
        2#0_01011_10101#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lwaux
        2#0_01010_10101#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '1', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwax
        2#0_10000_10110#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '1', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwbrx
        2#0_11000_10101#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwzcix
        2#0_00001_10111#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', DUPD), -- lwzux
        2#0_00000_10111#  =>  (LDST, NONE, OP_LOAD,      RA_OR_ZERO, RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- lwzx
        2#0_10010_00000#  =>  (ALU,  NONE, OP_MCRXRX,    NONE,       NONE,        NONE, NONE, '0', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- mcrxrx
        2#0_00000_10011#  =>  (ALU,  NONE, OP_MFCR,      NONE,       NONE,        NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- mfcr/mfocrf
        2#0_00010_10011#  =>  (ALU,  NONE, OP_MFMSR,     NONE,       NONE,        NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- mfmsr
        2#0_01010_10011#  =>  (ALU,  NONE, OP_MFSPR,     SPR,        NONE,        RS,   RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- mfspr
        2#0_01000_01001#  =>  (ALU,  NONE, OP_MOD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- modud
        2#0_01000_01011#  =>  (ALU,  NONE, OP_MOD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', NONE, '0', '0', NONE), -- moduw
        2#0_11000_01001#  =>  (ALU,  NONE, OP_MOD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', NONE, '0', '0', NONE), -- modsd
        2#0_11000_01011#  =>  (ALU,  NONE, OP_MOD,       RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '1', NONE, '0', '0', NONE), -- modsw
        2#0_00100_10000#  =>  (ALU,  NONE, OP_MTCRF,     NONE,       NONE,        RS,   NONE, '0', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- mtcrf/mtocrf
        2#0_00100_10010#  =>  (ALU,  NONE, OP_MTMSRD,    NONE,       NONE,        RS,   NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', NONE, '0', '1', NONE), -- mtmsr
        2#0_00101_10010#  =>  (ALU,  NONE, OP_MTMSRD,    NONE,       NONE,        RS,   NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- mtmsrd # ignore top bits and d
        2#0_01110_10011#  =>  (ALU,  NONE, OP_MTSPR,     NONE,       NONE,        RS,   SPR,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- mtspr
        2#0_00010_01001#  =>  (ALU,  NONE, OP_MUL_H64,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- mulhd
        2#0_00000_01001#  =>  (ALU,  NONE, OP_MUL_H64,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- mulhdu
        2#0_00010_01011#  =>  (ALU,  NONE, OP_MUL_H32,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- mulhw
        2#0_00000_01011#  =>  (ALU,  NONE, OP_MUL_H32,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- mulhwu
        -- next 4 have reserved bit set
        2#0_10010_01001#  =>  (ALU,  NONE, OP_MUL_H64,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- mulhd
        2#0_10000_01001#  =>  (ALU,  NONE, OP_MUL_H64,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- mulhdu
        2#0_10010_01011#  =>  (ALU,  NONE, OP_MUL_H32,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- mulhw
        2#0_10000_01011#  =>  (ALU,  NONE, OP_MUL_H32,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- mulhwu
        2#0_00111_01001#  =>  (ALU,  NONE, OP_MUL_L64,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- mulld
        2#0_10111_01001#  =>  (ALU,  NONE, OP_MUL_L64,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- mulldo
        2#0_00111_01011#  =>  (ALU,  NONE, OP_MUL_L64,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- mullw
        2#0_10111_01011#  =>  (ALU,  NONE, OP_MUL_L64,   RA,         RB,          NONE, RT,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- mullwo
        2#0_01110_11100#  =>  (ALU,  NONE, OP_AND,       NONE,       RB,          RS,   RA,   '0', '0', '0', '1', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- nand
        2#0_00011_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         NONE,        NONE, RT,   '0', '0', '1', '0', ONE,  '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- neg
        2#0_10011_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         NONE,        NONE, RT,   '0', '0', '1', '0', ONE,  '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- nego
        -- next 8 are reserved no-op instructions
        2#0_10000_10010#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- nop
        2#0_10001_10010#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- nop
        2#0_10010_10010#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- nop
        2#0_10011_10010#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- nop
        2#0_10100_10010#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- nop
        2#0_10101_10010#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- nop
        2#0_10110_10010#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- nop
        2#0_10111_10010#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- nop
        2#0_00011_11100#  =>  (ALU,  NONE, OP_OR,        NONE,       RB,          RS,   RA,   '0', '0', '0', '1', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- nor
        2#0_01101_11100#  =>  (ALU,  NONE, OP_OR,        NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- or
        2#0_01100_11100#  =>  (ALU,  NONE, OP_OR,        NONE,       RB,          RS,   RA,   '0', '0', '1', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- orc
        2#0_00011_11010#  =>  (ALU,  NONE, OP_POPCNT,    NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- popcntb
        2#0_01111_11010#  =>  (ALU,  NONE, OP_POPCNT,    NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- popcntd
        2#0_01011_11010#  =>  (ALU,  NONE, OP_POPCNT,    NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- popcntw
        2#0_00101_11010#  =>  (ALU,  NONE, OP_PRTY,      NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- prtyd
        2#0_00100_11010#  =>  (ALU,  NONE, OP_PRTY,      NONE,       NONE,        RS,   RA,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- prtyw
        2#0_00100_00000#  =>  (ALU,  NONE, OP_SETB,      NONE,       NONE,        NONE, RT,   '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- setb
        2#0_01111_10010#  =>  (LDST, NONE, OP_TLBIE,     NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- slbia
        2#0_00000_11011#  =>  (ALU,  NONE, OP_SHL,       NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- sld
        2#0_00000_11000#  =>  (ALU,  NONE, OP_SHL,       NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- slw
        2#0_11000_11010#  =>  (ALU,  NONE, OP_SHR,       NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '1', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- srad
        2#0_11001_11010#  =>  (ALU,  NONE, OP_SHR,       NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '1', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- sradi
        2#0_11001_11011#  =>  (ALU,  NONE, OP_SHR,       NONE,       CONST_SH,    RS,   RA,   '0', '0', '0', '0', ZERO, '1', NONE, '0', '0', '0', '0', '0', '1', RC,   '0', '0', NONE), -- sradi
        2#0_11000_11000#  =>  (ALU,  NONE, OP_SHR,       NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '1', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- sraw
        2#0_11001_11000#  =>  (ALU,  NONE, OP_SHR,       NONE,       CONST_SH32,  RS,   RA,   '0', '0', '0', '0', ZERO, '1', NONE, '0', '0', '0', '0', '1', '1', RC,   '0', '0', NONE), -- srawi
        2#0_10000_11011#  =>  (ALU,  NONE, OP_SHR,       NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- srd
        2#0_10000_11000#  =>  (ALU,  NONE, OP_SHR,       NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- srw
        2#0_11110_10101#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stbcix
        2#0_10101_10110#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '1', '0', '0', ONE,  '0', '0', NONE), -- stbcx
        2#0_00111_10111#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stbux
        2#0_00110_10111#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is1B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stbx
        2#0_10100_10100#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '1', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stdbrx
        2#0_11111_10101#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stdcix
        2#0_00110_10110#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '1', '0', '0', ONE,  '0', '0', NONE), -- stdcx
        2#0_00101_10101#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stdux
        2#0_00100_10101#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stdx
        2#0_10110_10111#  =>  (LDST, FPU,  OP_STORE,     RA_OR_ZERO, RB,          FRS,  NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stfdx
        2#0_10111_10111#  =>  (LDST, FPU,  OP_STORE,     RA_OR_ZERO, RB,          FRS,  RA,   '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stfdux
        2#0_11110_10111#  =>  (LDST, FPU,  OP_STORE,     RA_OR_ZERO, RB,          FRS,  NONE, '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stfiwx
        2#0_10100_10111#  =>  (LDST, FPU,  OP_STORE,     RA_OR_ZERO, RB,          FRS,  NONE, '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '1', '0', NONE, '0', '0', NONE), -- stfsx
        2#0_10101_10111#  =>  (LDST, FPU,  OP_STORE,     RA_OR_ZERO, RB,          FRS,  RA,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '1', '0', '1', '0', NONE, '0', '0', NONE), -- stfsux
        2#0_11100_10110#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is2B, '1', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- sthbrx
        2#0_11101_10101#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- sthcix
        2#0_10110_10110#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '0', '1', '0', '0', ONE,  '0', '0', NONE), -- sthcx
        2#0_01101_10111#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- sthux
        2#0_01100_10111#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is2B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- sthx
        2#0_00101_10110#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is8B, '0', '0', '0', '1', '0', '0', ONE,  '0', '0', DRSE), -- stqcx
        2#0_10100_10110#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is4B, '1', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stwbrx
        2#0_11100_10101#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stwcix
        2#0_00100_10110#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '1', '0', '0', ONE,  '0', '0', NONE), -- stwcx
        2#0_00101_10111#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '1', '0', '0', '0', NONE, '0', '0', NONE), -- stwux
        2#0_00100_10111#  =>  (LDST, NONE, OP_STORE,     RA_OR_ZERO, RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', is4B, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- stwx
        2#0_00001_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '1', '0', ONE,  '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subf
        2#0_10001_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '1', '0', ONE,  '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subfo
        2#0_00000_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '1', '0', ONE,  '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subfc
        2#0_10000_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '1', '0', ONE,  '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subfco
        2#0_00100_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '1', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subfe
        2#0_10100_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         RB,          NONE, RT,   '0', '0', '1', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subfeo
        2#0_00111_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         CONST_M1,    NONE, RT,   '0', '0', '1', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subfme
        2#0_10111_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         CONST_M1,    NONE, RT,   '0', '0', '1', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subfmeo
        2#0_00110_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         NONE,        NONE, RT,   '0', '0', '1', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subfze
        2#0_10110_01000#  =>  (ALU,  NONE, OP_ADD,       RA,         NONE,        NONE, RT,   '0', '0', '1', '0', CA,   '1', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- subfzeo
        2#0_10010_10110#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- sync
        2#0_00010_00100#  =>  (ALU,  NONE, OP_TRAP,      RA,         RB,          NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- td
        2#0_00000_00100#  =>  (ALU,  NONE, OP_TRAP,      RA,         RB,          NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', NONE, '0', '1', NONE), -- tw
        2#0_01001_10010#  =>  (LDST, NONE, OP_TLBIE,     NONE,       RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- tlbie
        2#0_01000_10010#  =>  (LDST, NONE, OP_TLBIE,     NONE,       RB,          RS,   NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- tlbiel
        2#0_10001_10110#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- tlbsync
        2#0_00000_11110#  =>  (ALU,  NONE, OP_NOP,       NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- wait
        2#0_01001_11100#  =>  (ALU,  NONE, OP_XOR,       NONE,       RB,          RS,   RA,   '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- xor

        -- Major opcode 19
        -- Columns with insn(4) = '1' are all illegal and not mapped here; to
        -- fit into 2048 entries, the columns are remapped so that 16-24 are
        -- stored here as 8-15; in other words the address bits are
        -- 1 insn(10..6) 1 insn(5) insn(3..1)
        2#1_10000_11000#  =>  (ALU,  NONE, OP_BCREG,     SPR,        SPR,         NONE, SPR,  '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '1', '0', NONE), -- bcctr
        2#1_00000_11000#  =>  (ALU,  NONE, OP_BCREG,     SPR,        SPR,         NONE, SPR,  '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '1', '0', NONE), -- bclr
        2#1_10001_11000#  =>  (ALU,  NONE, OP_BCREG,     SPR,        SPR,         NONE, SPR,  '1', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '1', '0', NONE), -- bctar
        2#1_01000_10001#  =>  (ALU,  NONE, OP_CROP,      NONE,       NONE,        NONE, NONE, '1', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- crand
        2#1_00100_10001#  =>  (ALU,  NONE, OP_CROP,      NONE,       NONE,        NONE, NONE, '1', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- crandc
        2#1_01001_10001#  =>  (ALU,  NONE, OP_CROP,      NONE,       NONE,        NONE, NONE, '1', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- creqv
        2#1_00111_10001#  =>  (ALU,  NONE, OP_CROP,      NONE,       NONE,        NONE, NONE, '1', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- crnand
        2#1_00001_10001#  =>  (ALU,  NONE, OP_CROP,      NONE,       NONE,        NONE, NONE, '1', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- crnor
        2#1_01110_10001#  =>  (ALU,  NONE, OP_CROP,      NONE,       NONE,        NONE, NONE, '1', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- cror
        2#1_01101_10001#  =>  (ALU,  NONE, OP_CROP,      NONE,       NONE,        NONE, NONE, '1', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- crorc
        2#1_00110_10001#  =>  (ALU,  NONE, OP_CROP,      NONE,       NONE,        NONE, NONE, '1', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- crxor
        2#1_00100_11110#  =>  (ALU,  NONE, OP_ISYNC,     NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '1', NONE), -- isync
        2#1_00000_10000#  =>  (ALU,  NONE, OP_CROP,      NONE,       NONE,        NONE, NONE, '1', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- mcrf
        2#1_00000_11010#  =>  (ALU,  NONE, OP_RFID,      SPR,        SPR,         NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- rfid

        -- Major opcode 59
        -- Only column 14 is valid here (columns 16-31 are handled in the major
        -- table) and it (column 14) is mapped to column 6 of the space which
        -- is mostly used for opcode 19.
        2#1_11010_10110#  =>  (FPU,  FPU,  OP_FPOP_I,    NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fcfids
        2#1_11110_10110#  =>  (FPU,  FPU,  OP_FPOP_I,    NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), -- fcfidus

        -- Major opcode 63
        -- Columns 0-15 are mapped here; columns 16-31 are in the major table.
        -- Address bits are 1 insn(10:6) 0 insn(4:1)
        --                unit fac  internal       in1   in2   in3   out   CR   CR   inv  inv  cry   cry  ldst  BR   sgn  upd  rsrv 32b  sgn  rc    lk   sgl  rpt
        --                                op                               in   out   A   out  in    out  len        ext                                pipe
        2#1_00000_00000#  =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, NONE, '0', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), --  0/0=fcmpu
        2#1_00001_00000#  =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, NONE, '0', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), --  1/0=fcmpo
        2#1_00010_00000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       NONE,        NONE, NONE, '0', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), --  2/0=mcrfs
        2#1_00100_00000#  =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, NONE, '0', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), --  4/0=ftdiv
        2#1_00101_00000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, NONE, '0', '1', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), --  5/0=ftsqrt
        2#1_00001_00110#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  1/6=mtfsb1
        2#1_00010_00110#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  2/6=mtfsb0
        2#1_00100_00110#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  4/6=mtfsfi
        2#1_11010_00110#  =>  (FPU,  FPU,  OP_FPOP_I,    FRA,        FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- 26/6=fmrgow
        2#1_11110_00110#  =>  (FPU,  FPU,  OP_FPOP_I,    FRA,        FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE), -- 30/6=fmrgew
        2#1_10010_00111#  =>  (FPU,  FPU,  OP_FPOP_I,    NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 18/7=mffs family
        2#1_10110_00111#  =>  (FPU,  FPU,  OP_FPOP_I,    NONE,       FRB,         NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 22/7=mtfsf
        2#1_00000_01000#  =>  (FPU,  FPU,  OP_FPOP,      FRA,        FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  0/8=fcpsgn
        2#1_00001_01000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  1/8=fneg
        2#1_00010_01000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  2/8=fmr
        2#1_00100_01000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  4/8=fnabs
        2#1_01000_01000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  8/8=fabs
        2#1_01100_01000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 12/8=frin
        2#1_01101_01000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 13/8=friz
        2#1_01110_01000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 14/8=frip
        2#1_01111_01000#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 15/8=frim
        2#1_00000_01100#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '1', '0', RC,   '0', '0', NONE), --  0/12=frsp
        2#1_00000_01110#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  0/14=fctiw
        2#1_00100_01110#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  4/14=fctiwu
        2#1_11001_01110#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 25/14=fctid
        2#1_11010_01110#  =>  (FPU,  FPU,  OP_FPOP_I,    NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 26/14=fcfid
        2#1_11101_01110#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 29/14=fctidu
        2#1_11110_01110#  =>  (FPU,  FPU,  OP_FPOP_I,    NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 30/14=fcfidu
        2#1_00000_01111#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  0/15=fctiwz
        2#1_00100_01111#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), --  4/15=fctiwuz
        2#1_11001_01111#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 25/15=fctidz
        2#1_11101_01111#  =>  (FPU,  FPU,  OP_FPOP,      NONE,       FRB,         NONE, FRT,  '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', RC,   '0', '0', NONE), -- 29/15=fctiduz
        others => illegal_inst
        );

    attribute ram_style : string;
    attribute ram_style of major_decode_rom : signal is "block";
    attribute ram_style of row_decode_rom : signal is "block";

    --                                        unit   fac   internal         in1         in2          in3   out   CR   CR   inv  inv  cry   cry  ldst  BR   sgn  upd  rsrv 32b  sgn  rc    lk   sgl  rpt
    --                                                           op                                              in   out   A   out  in    out  len        ext                                 pipe
    constant nop_instr      : decode_rom_t := (ALU,  NONE, OP_NOP,          NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE);
    constant fetch_fail_inst: decode_rom_t := (LDST, NONE, OP_FETCH_FAILED, NONE,       NONE,        NONE, NONE, '0', '0', '0', '0', ZERO, '0', NONE, '0', '0', '0', '0', '0', '0', NONE, '0', '0', NONE);

begin
    decode1_0: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                r <= Decode1ToDecode2Init;
                s <= Decode1ToDecode2Init;
                ri <= reg_internal_t_init;
                si <= reg_internal_t_init;
            elsif flush_in = '1' then
                r.valid <= '0';
                s.valid <= '0';
            elsif s.valid = '1' then
                if stall_in = '0' then
                    r <= s;
                    ri <= si;
                    s.valid <= '0';
                end if;
            else
                s <= rin;
                si <= ri_in;
                s.valid <= rin.valid and r.valid and stall_in;
                if r.valid = '0' or stall_in = '0' then
                    r <= rin;
                    ri <= ri_in;
                end if;
            end if;
            if rst = '1' then
                br.br_nia <= (others => '0');
                br.br_offset <= (others => '0');
                br.predict <= '0';
            else
                br <= br_in;
            end if;
        end if;
    end process;
    busy_out <= s.valid;

    decode1_1: process(all)
        variable v : Decode1ToDecode2Type;
        variable vi : reg_internal_t;
        variable majorop : std_ulogic_vector(5 downto 0);
        variable majaddr : std_ulogic_vector(10 downto 0);
        variable rowaddr : std_ulogic_vector(10 downto 0);
        variable sprn : spr_num_t;
        variable br_target : std_ulogic_vector(61 downto 0);
        variable br_offset : signed(23 downto 0);
        variable bv : br_predictor_t;
    begin
        v := Decode1ToDecode2Init;
        vi := reg_internal_t_init;

        v.valid := f_in.valid;
        v.nia  := f_in.nia;
        v.insn := f_in.insn;
        v.stop_mark := f_in.stop_mark;
        v.big_endian := f_in.big_endian;

        if f_in.valid = '1' then
            report "Decode insn " & to_hstring(f_in.insn) & " at " & to_hstring(f_in.nia);
        end if;

        br_offset := (others => '0');

        majaddr := f_in.insn(31 downto 26) & f_in.insn(4 downto 0);
        vi.maj_decode := major_decode_rom(to_integer(unsigned(majaddr)));

        -- row_decode_rom is used for op 19, 31, 59, 63
        -- addr bit 10 is 0 for op 31, 1 for 19, 59, 63
        rowaddr(10) := f_in.insn(31) or not f_in.insn(29);
        rowaddr(9 downto 5) := f_in.insn(10 downto 6);
        if f_in.insn(28) = '0' then
            -- op 19 and op 59
            rowaddr(4 downto 3) := '1' & f_in.insn(5);
        else
            -- op 31 and 63; for 63 we only use this when f_in.insn(5) = '0'
            rowaddr(4 downto 3) := f_in.insn(5 downto 4);
        end if;
        rowaddr(2 downto 0) := f_in.insn(3 downto 1);
        vi.row_decode := row_decode_rom(to_integer(unsigned(rowaddr)));

        majorop := f_in.insn(31 downto 26);
        case to_integer(unsigned(majorop)) is
        when 4 =>
            -- major opcode 4, mostly VMX/VSX stuff but also some integer ops (madd*)
            vi.override := not f_in.insn(5);

        when 31 =>
            -- major opcode 31, lots of things
            vi.use_row := '1';

            -- Work out ispr1/ispro independent of v.decode since they seem to be critical path
            sprn := decode_spr_num(f_in.insn);
            v.ispr1 := fast_spr_num(sprn);
            v.ispro := fast_spr_num(sprn);

            if std_match(f_in.insn(10 downto 1), "01-1010011") then
                -- mfspr or mtspr
                -- Make slow SPRs single issue
                if is_fast_spr(v.ispr1) = '0' then
                    vi.force_single := '1';
                    -- send MMU-related SPRs to loadstore1
                    case sprn is
                        when SPR_DAR | SPR_DSISR | SPR_PID | SPR_PTCR =>
                            vi.override_decode.unit := LDST;
                            vi.override_unit := '1';
                        when others =>
                    end case;
                end if;
            end if;
            if std_match(f_in.insn(10 downto 1), "0100010100") then
                -- lqarx, illegal if RA = RT or RB = RT
                if f_in.insn(25 downto 21) = f_in.insn(20 downto 16) or
                    f_in.insn(25 downto 21) = f_in.insn(15 downto 11) then
                    vi.override := '1';
                end if;
            end if;

        when 16 =>
            -- CTR may be needed as input to bc
            if f_in.insn(23) = '0' then
                v.ispr1 := fast_spr_num(SPR_CTR);
                v.ispro := fast_spr_num(SPR_CTR);
            elsif f_in.insn(0) = '1' then
                v.ispro := fast_spr_num(SPR_LR);
            end if;
            -- Predict backward branches as taken, forward as untaken
            v.br_pred := f_in.insn(15);
            br_offset := resize(signed(f_in.insn(15 downto 2)), 24);

        when 18 =>
            -- Unconditional branches are always taken
            v.br_pred := '1';
            br_offset := signed(f_in.insn(25 downto 2));
            if f_in.insn(0) = '1' then
                v.ispro := fast_spr_num(SPR_LR);
            end if;

        when 19 =>
            -- Columns 8-15 and 24-31 don't have any valid instructions
            -- (where insn(5..1) is the column number).
            -- addpcis (column 2) is in the major table
            -- Use the row table for columns 0-1 and 16-23 (mapped to 8-15)
            -- Columns 4-7 in the row table are used for op 59 cols 12-15
            vi.override := f_in.insn(4);
            vi.use_row := f_in.insn(5) or (not f_in.insn(3) and not f_in.insn(2));

            -- Work out ispr1/ispr2 independent of vi.row_decode since they seem to be critical path
            if f_in.insn(2) = '0' then
                -- Could be OP_BCREG: bclr, bcctr, bctar
                -- Branch uses CTR as condition when BO(2) is 0. This is
                -- also used to indicate that CTR is modified (they go
                -- together).
                -- bcctr doesn't update CTR or use it in the branch condition
                if f_in.insn(23) = '0' and (f_in.insn(10) = '0' or f_in.insn(6) = '1') then
                    v.ispr1 := fast_spr_num(SPR_CTR);
                    v.ispro := fast_spr_num(SPR_CTR);
                elsif f_in.insn(0) = '1' then
                    v.ispro := fast_spr_num(SPR_LR);
                end if;
                if f_in.insn(10) = '0' then
                    v.ispr2 := fast_spr_num(SPR_LR);
                elsif f_in.insn(6) = '0' then
                    v.ispr2 := fast_spr_num(SPR_CTR);
                else
                    v.ispr2 := fast_spr_num(SPR_TAR);
                end if;
            else
                -- Could be OP_RFID
                v.ispr1 := fast_spr_num(SPR_SRR1);
                v.ispr2 := fast_spr_num(SPR_SRR0);
            end if;

        when 24 =>
            -- ori, special-case the standard NOP
            if std_match(f_in.insn, "01100000000000000000000000000000") then
                report "PPC_nop";
                vi.override := '1';
                vi.override_decode := nop_instr;
            end if;

        when 56 =>
            -- lq, illegal if RA = RT
            if f_in.insn(25 downto 21) = f_in.insn(20 downto 16) then
                vi.override := '1';
            end if;

        when 59 =>
            if HAS_FPU then
                -- floating point operations, mostly single-precision
                -- Use row table for columns 12-15, column table for 16-31
                vi.override := not f_in.insn(5) and (not f_in.insn(4) or not f_in.insn(3));
                vi.use_row := not f_in.insn(5);
            end if;

        when 63 =>
            if HAS_FPU then
                -- floating point operations, general and double-precision
                vi.use_row := not f_in.insn(5);
            end if;

        when others =>
        end case;

        if f_in.fetch_failed = '1' then
            v.valid := '1';
            vi.override := '1';
            vi.override_decode := fetch_fail_inst;
            -- Only send down a single OP_FETCH_FAILED
            if ri.override = '1' and ri.override_decode.insn_type = OP_FETCH_FAILED then
                v.valid := '0';
            end if;
        end if;

        -- Branch predictor
        -- Note bclr, bcctr and bctar are predicted not taken as we have no
        -- count cache or link stack.
        bv.br_nia := f_in.nia(63 downto 2);
        if f_in.insn(1) = '1' then
            bv.br_nia := (others => '0');
        end if;
        bv.br_offset := br_offset;
        if f_in.next_predicted = '1' then
            v.br_pred := '1';
        end if;
        bv.predict := v.br_pred and f_in.valid and not flush_in and not busy_out and not f_in.next_predicted;
        -- after a clock edge...
        br_target := std_ulogic_vector(signed(br.br_nia) + br.br_offset);

        -- Update registers
        rin <= v;
        ri_in <= vi;
        br_in <= bv;

        -- Update outputs
        d_out <= r;
        if ri.override = '1' then
            d_out.decode <= ri.override_decode;
        else
            if ri.use_row = '1' then
                d_out.decode <= ri.row_decode;
            else
                d_out.decode <= ri.maj_decode;
            end if;
            if ri.override_unit = '1' then
                d_out.decode.unit <= ri.override_decode.unit;
            end if;
        end if;
        if ri.force_single = '1' then
            d_out.decode.sgl_pipe <= '1';
        end if;
        f_out.redirect <= br.predict;
        f_out.redirect_nia <= br_target & "00";
        flush_out <= bv.predict or br.predict;
    end process;

    d1_log: if LOG_LENGTH > 0 generate
        signal log_data : std_ulogic_vector(12 downto 0);
    begin
        dec1_log : process(clk)
        begin
            if rising_edge(clk) then
                log_data <= std_ulogic_vector(to_unsigned(insn_type_t'pos(d_out.decode.insn_type), 6)) &
                            r.nia(5 downto 2) &
                            std_ulogic_vector(to_unsigned(unit_t'pos(d_out.decode.unit), 2)) &
                            r.valid;
            end if;
        end process;
        log_out <= log_data;
    end generate;

end architecture behaviour;
