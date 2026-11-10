#!/usr/bin/env python3
"""Embed firmware.bin into ../testbench.v.

Rewrites the block between the FIRMWARE-BEGIN / FIRMWARE-END markers and the
FW_WORDS parameter, so the testbench stays a single self-contained file that
can be pasted into VeriSim.

Usage: embed.py firmware.bin ../testbench.v
"""
import re
import struct
import sys

bin_path, tb_path = sys.argv[1], sys.argv[2]

data = open(bin_path, "rb").read()
data += b"\0" * (-len(data) % 4)
words = struct.unpack("<%dI" % (len(data) // 4), data)

rows = []
for i in range(0, len(words), 4):
    rows.append("        " + " ".join(
        "fw[%3d] = 32'h%08x;" % (i + j, w) for j, w in enumerate(words[i:i + 4])))
block = "\n".join(rows) + "\n"

tb = open(tb_path).read()
tb, n1 = re.subn(r"(// FIRMWARE-BEGIN[^\n]*\n).*?( *// FIRMWARE-END)",
                 lambda m: m.group(1) + block + m.group(2), tb, flags=re.S)
tb, n2 = re.subn(r"localparam FW_WORDS = \d+;", "localparam FW_WORDS = %d;" % len(words), tb)
if n1 != 1 or n2 != 1:
    sys.exit("embed.py: markers or FW_WORDS not found in " + tb_path)
open(tb_path, "w").write(tb)
print("embedded %d words (%d bytes) into %s" % (len(words), len(data), tb_path))
