#!/usr/bin/python3
from fusesoc.capi2.generator import Generator
from litex.build.tools import write_to_file
from litex.soc.integration.builder import *
from litedram.gen import *
import subprocess
import os
import sys
import yaml

class LiteDRAMGenerator(Generator):
    def run(self):
        board    = self.config.get('board')

        print("Generating LiteDRAM for board... ", board)

        # Collect a bunch of directory path
        script_dir = os.path.dirname(sys.argv[0])
        build_dir = os.path.join(os.getcwd(), "build", "software")
        gen_inc_dir = os.path.join(build_dir, "include")
        generated_dir = os.path.join(gen_inc_dir, "generated")
        src_dir = os.path.join(script_dir, "sdram_init")
        lxbios_src_dir = os.path.join(soc_directory, "software", "bios")
        lxbios_inc_dir = os.path.join(soc_directory, "software", "include")
        print(" Script dir:", script_dir)
        print("  Build dir:", build_dir)
        print("    Gen dir:", generated_dir)
        print("    src dir:", src_dir)
        print(" lx src dir:", lxbios_src_dir)
        print(" lx inc dir:", lxbios_inc_dir)

        print(" Generating DRAM controller verilog... ")

        # XXX FIXME: Move to ../fpga/<board>/litedram.yml and use os.path.*
        filename = script_dir + "/" + board + ".yml"
        core_config = yaml.load(open(filename).read(), Loader=yaml.Loader)

        # Convert YAML elements to Python/LiteX
        for k, v in core_config.items():
            replaces = {"False": False, "True": True, "None": None}
            for r in replaces.keys():
                if v == r:
                    core_config[k] = replaces[r]
            if "clk_freq" in k:
                core_config[k] = float(core_config[k])
            if k == "sdram_module":
                core_config[k] = getattr(litedram_modules, core_config[k])
            if k == "sdram_phy":
                core_config[k] = getattr(litedram_phys, core_config[k])

        # Generate core
        platform = Platform()
        soc = LiteDRAMCore(platform, core_config, integrated_rom_size=0)
        builder = Builder(soc, output_dir="build", compile_gateware=False)
        vns = builder.build(build_name="litedram_core", regular_comb=False)

        # Generate mem.h
        mem_h = "#define MAIN_RAM_BASE 0x40000000"
        write_to_file(os.path.join(generated_dir, "mem.h"), mem_h)
        
        # Environment
        env_vars = []
        def _makefile_escape(s):  # From LiteX
            return s.replace("\\", "\\\\")
        def add_var(k, v):
            env_vars.append("{}={}\n".format(k, _makefile_escape(v)))
        add_var("BUILD_DIR", build_dir)
        add_var("SRC_DIR", src_dir)
        add_var("GENINC_DIR", gen_inc_dir)
        add_var("LXSRC_DIR", lxbios_src_dir)
        add_var("LXINC_DIR", lxbios_inc_dir)
        write_to_file(
            os.path.join(generated_dir, "variables.mak"), "".join(env_vars))

        # Build init code
        print(" Generating init software...")
        makefile = os.path.join(src_dir, "Makefile")
        foo = subprocess.check_call(["make", "-C", build_dir, "-f", makefile])
        print("Make result ", foo)
        os.system("mv build/software/obj/sdram_init.hex build/gateware/")
        os.system("cp " +  script_dir + "/litedram-wrapper.vhdl build/gateware/")

        files = []
        files.append({'build/gateware/litedram_core.v' : {'file_type' : 'verilogSource'}})
        files.append({'build/gateware/litedram-wrapper.vhdl' : {'file_type' : 'vhdlSource-2008'}})
        files.append({'build/gateware/sdram_init.hex' : {'file_type' : 'user'}})
        self.add_files(files)

g = LiteDRAMGenerator()
g.run()
g.write()

