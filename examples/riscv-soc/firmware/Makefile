# Builds the demo firmware and embeds it into ../testbench.v
#   make          build firmware.elf / .bin / .lst and update ../testbench.v
#   make clean    remove build products
CROSS  ?= riscv64-unknown-elf-
CFLAGS  = -march=rv32imc_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib -Wall -Wextra

all: firmware.bin
	python3 embed.py firmware.bin ../testbench.v

firmware.bin: firmware.elf
	$(CROSS)objcopy -O binary firmware.elf firmware.bin

firmware.elf: crt0.S main.c soc.h link.ld
	$(CROSS)gcc $(CFLAGS) -Wl,--no-warn-rwx-segments -Tlink.ld -o firmware.elf crt0.S main.c
	$(CROSS)objdump -d firmware.elf > firmware.lst

clean:
	rm -f firmware.elf firmware.bin firmware.lst

.PHONY: all clean
