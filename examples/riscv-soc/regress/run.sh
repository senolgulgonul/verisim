#!/bin/sh
# Runs the official riscv-tests with the official "p" environment (needs CSRs/traps).
# First:
#   git clone --recursive https://github.com/riscv-software-src/riscv-tests
# Usage:
#   ./run.sh        rv32ui/um/uc/mi; ui and um are built both as rv32im and as rv32imc
#   ./run.sh irq    the same user-level tests under random interrupts (env_irq)
# Environment: DESIGN=file.v (default design.v), IVERILOG / VVP to pick another Icarus
R=riscv-tests; T=$R/isa
MODE=${1:-std}
IVERILOG=${IVERILOG:-iverilog}; VVP=${VVP:-vvp}
mkdir -p build
$IVERILOG -g2005 -o build/sim tb_regress.v ${DESIGN:-../design.v} || exit 1
if [ $MODE = irq ]; then ENV=env_irq; SUITES="rv32ui rv32um rv32uc"; PLUS=+irq
else                     ENV=$R/env/p; SUITES="rv32ui rv32um rv32uc rv32mi"; PLUS=; fi
pass=0; fail=0
for march in rv32im rv32imc; do
  for suite in $SUITES; do
    for s in $T/$suite/*.S; do
      n=$(basename $s .S)
      case $n in fence_i) continue;; esac                      # no Zifencei
      [ $suite = rv32uc ] && [ $march = rv32im ] && continue
      [ $suite = rv32mi ] && [ $march = rv32imc ] && continue
      case $suite/$n in
        rv32ui/ma_data)                     continue;;         # expects misaligned access to work; we trap
        rv32mi/breakpoint|rv32mi/pmpaddr)   continue;;         # no debug triggers (tselect) / no PMP
      esac
      riscv64-unknown-elf-gcc -march=${march}_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
         -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments \
         -I$ENV -I$R/env -I$T/macros/scalar -T$R/env/p/link.ld -o build/$n.elf $s || exit 1
      riscv64-unknown-elf-objcopy -O binary build/$n.elf build/$n.bin
      od -An -v -tx4 -w4 build/$n.bin | tr -d ' ' > build/$n.hex
      th=$(riscv64-unknown-elf-nm build/$n.elf | awk '$3=="tohost"{print $1}')
      r=$($VVP -n build/sim +hex=build/$n.hex +tohost=$th $PLUS | grep -E 'PASS|FAIL')
      printf "%-8s %-7s %-18s %s\n" $march $suite $n "$r"
      case "$r" in PASS*) pass=$((pass+1));; *) fail=$((fail+1));; esac
    done
  done
done
echo "== $pass passed, $fail failed =="
