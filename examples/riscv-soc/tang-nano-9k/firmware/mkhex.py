#!/usr/bin/env python3
"""Split firmware.bin into four hex files, one per byte lane of the block RAM.

firmware_b0.hex holds bits 7:0 of every 32-bit word, firmware_b1.hex bits 15:8,
and so on. Each file has one 2-digit byte per line and is padded with zeros to
the full RAM depth, which is what $readmemh in soc_ram expects.

Usage: mkhex.py firmware.bin output_dir [ram_words]
"""
import os
import sys

bin_path, out_dir = sys.argv[1], sys.argv[2]
ram_words = int(sys.argv[3]) if len(sys.argv) > 3 else 4096

data = open(bin_path, "rb").read()
if len(data) > 4 * ram_words:
    sys.exit("mkhex.py: firmware (%d bytes) does not fit in %d bytes of RAM" % (len(data), 4 * ram_words))
data += b"\0" * (4 * ram_words - len(data))

for lane in range(4):
    path = os.path.join(out_dir, "firmware_b%d.hex" % lane)
    with open(path, "w") as f:
        for word in range(ram_words):
            f.write("%02x\n" % data[4 * word + lane])
print("wrote firmware_b0..3.hex (%d words each) to %s" % (ram_words, out_dir))
