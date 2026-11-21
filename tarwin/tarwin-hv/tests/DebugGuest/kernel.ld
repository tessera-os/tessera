ENTRY(guest_start)
PHDRS { kernel PT_LOAD FLAGS(5); }
SECTIONS {
    . = 0x10000;
    .text : { *(.text.guest_entry) *(.text .text.*) } :kernel
    .rodata : { *(.rodata .rodata.* .srodata .srodata.* .data.rel.ro* .got*) } :kernel
    .data : { *(.data .data.*) *(.sdata .sdata.*) } :kernel
    .bss : { *(.sbss .sbss.* .bss .bss.*) *(COMMON) } :kernel
    __global_pointer$ = 0x10800;
    ASSERT(SIZEOF(.data) == 0 && SIZEOF(.bss) == 0, "guest kernel needs separate writable backing")
    ASSERT(. < 0x100000, "guest kernel overlaps stack")
}
