#!/bin/sh
# Optional: build the bitstream with the open-source toolchain instead of Gowin IDE.
# Needs Yosys, nextpnr-himbaechel (Gowin) and Apicula, for example the YoWASP builds:
#   pip install yowasp-yosys yowasp-nextpnr-himbaechel-gowin apycula
# Run from this folder; the result is build/tang9k_oss.fs.
set -e
YOSYS=${YOSYS:-yowasp-yosys}
NEXTPNR=${NEXTPNR:-yowasp-nextpnr-himbaechel-gowin}
mkdir -p build
cp ../design.v tang9k_top.v tang9k.cst firmware_b0.hex firmware_b1.hex firmware_b2.hex firmware_b3.hex build/
cd build
$YOSYS -q -p "read_verilog design.v tang9k_top.v; synth_gowin -top tang9k_top -family gw1n -json tang9k.json"
$NEXTPNR --json tang9k.json --write tang9k_pnr.json --device GW1NR-LV9QN88PC6/I5 \
         --vopt family=GW1N-9C --vopt cst=tang9k.cst --freq 27
gowin_pack -d GW1N-9C -o tang9k_oss.fs tang9k_pnr.json
echo "bitstream: build/tang9k_oss.fs   (load with: openFPGALoader -b tangnano9k build/tang9k_oss.fs)"
