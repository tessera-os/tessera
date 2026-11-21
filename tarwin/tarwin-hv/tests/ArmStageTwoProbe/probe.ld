ENTRY(_start)
SECTIONS {
  . = 0x40080000;
  .text : { *(.text.entry) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  .bss (NOLOAD) : { *(.bss .bss.*) *(COMMON) }
}
