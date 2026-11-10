# Builds the Tang Nano 9K firmware and the four hex files that preload the block RAM.
# The startup code, linker script and register map are shared with ../../firmware.
#   make          build and write ../firmware_b0.hex .. ../firmware_b3.hex
#   make clean    remove build products (the hex files are kept)
CROSS  ?= riscv64-unknown-elf-
COMMON  = ../../firmware
CFLAGS  = -march=rv32imc_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib -Wall -Wextra -I$(COMMON)

all: firmware.bin
	python3 mkhex.py firmware.bin ..

firmware.bin: firmware.elf
	$(CROSS)objcopy -O binary firmware.elf firmware.bin

firmware.elf: main.c $(COMMON)/crt0.S $(COMMON)/soc.h $(COMMON)/link.ld
	$(CROSS)gcc $(CFLAGS) -Wl,--no-warn-rwx-segments -T$(COMMON)/link.ld -o firmware.elf $(COMMON)/crt0.S main.c
	$(CROSS)objdump -d firmware.elf > firmware.lst

clean:
	rm -f firmware.elf firmware.bin firmware.lst

.PHONY: all clean
