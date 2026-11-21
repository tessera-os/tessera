ENTRY(_start)
PHDRS { entry PT_LOAD FLAGS(5); data PT_LOAD FLAGS(6); note PT_NOTE FLAGS(4); }
SECTIONS {
  . = 0x100000;
  .note.Xen : { KEEP(*(.note.Xen)) } :entry :note
  .text : { *(.text.entry) *(.text .text.*) } :entry
  .rodata : { *(.rodata .rodata.*) } :entry
  .data ALIGN(4096) : { *(.data .data.*) } :data
  .bss (NOLOAD) : { *(.bss .bss.*) *(COMMON) } :data
}
