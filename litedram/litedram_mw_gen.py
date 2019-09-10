#!/usr/bin/python3
from fusesoc.capi2.generator import Generator
import subprocess
import os
import sys

class LiteDRAMGenerator(Generator):
    def run(self):
        board    = self.config.get('board')

        print("Hello World ! ", os.getcwd())
        script_dir = os.path.dirname(sys.argv[0])
        filename = script_dir + "/" + board + ".yml"
        args = ['litedram_gen', filename ]
        rc = subprocess.call(args)
        if rc:
            exit(1)
        files = []
        files.append({'build/gateware/litedram_core.v' : {'file_type' : 'verilogSource'}})
        files.append({'build/gateware/litedram_core.init' : {'file_type' : 'user'}})
        self.add_files(files)
        print("Core file:", self.core_file)

g = LiteDRAMGenerator()
g.run()
g.write()

# XXX Improve this by digging address bits out with something like this
# and generate the parameters
#sed -n '/user_port0_cmd_addr,/s/.*\[\(.*\):[0-9]*\].*/\1/p' /home/ANT.AMAZON.COM/benh/hackplace/microwatt-fusesoc/build/microwatt_0/src/microwatt-dram_arty_0/build/gateware/litedram_core.v
