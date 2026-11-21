#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pkgs=$(cd "$here/../../../.." && pwd)
arch="$pkgs/tarwin/tarwin-arch-aarch64/Sources/TarwinArchAarch64"
bin=$(dirname "${EMBEDDED_SWIFTC:?macOS Swift toolchain with Embedded modules required}")
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
swiftc "$arch/ArmTrapLayout.swift" "$pkgs/tessera/build/tarwin-stage0/ArmHostTrap.swift" -o "$d/emit"
"$d/emit" > "$d/host.S"
swift "$here/HostProbe.swift" > "$d/start.S"
flags=(-target aarch64-none-none-elf -enable-experimental-feature Embedded -no-allocations
       -enable-experimental-feature Extern -swift-version 6 -Osize -wmo -parse-as-library
       -Xfrontend -disable-stack-protector -Xcc -mgeneral-regs-only -I "$d")
"$bin/swiftc" "${flags[@]}" -emit-module -module-name TarwinArchAarch64 -emit-module-path \
  "$d/TarwinArchAarch64.swiftmodule" "$arch"/*.swift
"$bin/swiftc" "${flags[@]}" -emit-ir "$here/Probe.swift" "$here/../FirmwareProbe/Memory.swift" -o "$d/probe.ll"
"$bin/clang" -target aarch64-none-none-elf -ffunction-sections -fdata-sections -Oz -c "$d/probe.ll" -o "$d/probe.o"
for src in start host; do
  "$bin/clang" -target aarch64-none-none-elf -march=armv8.5-a+memtag -c "$d/$src.S" -o "$d/$src.o"
done
cat > "$d/sections" <<'LD'
ENTRY(_start)
SECTIONS {
 . = 0x40080000; .text : { *(.text.boot) *(.text*) *(.rodata*) }
 ASSERT(. <= 0x40088000, "probe code exceeds its two privileged RX pages")
 . = 0x40088000; .data : { *(.data*) *(.bss*) }
 ASSERT(. <= 0x40200000, "probe data reaches the private sample")
 . = 0x40200000; .sample : { KEEP(*(.sample)) }
}
LD
"$bin/ld.lld" --gc-sections -T "$d/sections" "$d/start.o" "$d/host.o" "$d/probe.o" -o "$d/probe.elf"
# Bound a guest whose unhandled exception correctly stops the boot CPU.
perl -e 'alarm 10; exec @ARGV' qemu-system-aarch64 -machine virt,virtualization=on \
  -cpu max -smp 1 -m 128M -nodefaults -nographic -monitor none -serial none \
  -semihosting-config enable=on,target=native -kernel "$d/probe.elf" >"$d/log" 2>&1 || {
  cat "$d/log" >&2; exit 1
}
grep -Fx 'VHE-COPY-READ-WRITE-ABORT-DENY' "$d/log"
grep -Fx 'VHE-HIGH-HOST-PRIVATE-ROOT-SWITCH' "$d/log"
