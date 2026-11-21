ENTRY(_start)
SECTIONS {
  . = 0x80200000;
  .text : { *(.text.entry) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) }
  .data : { __global_pointer$ = . + 0x800; *(.sdata .sdata.*) *(.data .data.*) }
  .bss (NOLOAD) : { *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON) }
}
