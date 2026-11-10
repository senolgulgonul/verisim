/* Code and data share one RAM image starting at address 0 */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K }
SECTIONS {
  .text : { *(.text.init) *(.text*) }                       > RAM
  .rodata : { *(.rodata*) *(.srodata*) }                    > RAM
  .data : { *(.data*) *(.sdata*) . = ALIGN(4); }            > RAM
  _image_end = .;
  .bss  : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > RAM
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
