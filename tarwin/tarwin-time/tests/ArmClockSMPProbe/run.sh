#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pkg=$(cd "$here/../.." && pwd)
bin=$(dirname "${EMBEDDED_SWIFTC:?Embedded Swift toolchain required}")
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
t=aarch64-none-none-elf
flags=(-target "$t" -enable-experimental-feature Embedded -enable-experimental-feature Extern
  -enable-experimental-feature Volatile -no-allocations -Osize -wmo -parse-as-library -swift-version 6
  -Xfrontend -disable-stack-protector -Xcc -mgeneral-regs-only -Xcc -mstrict-align -I "$d")
for src in "$pkg/../kcore/Sources/KCore" "$pkg/../tarwin-boot/Sources/TarwinBoot" \
  "$pkg/../tarwin-arch-aarch64/Sources/TarwinArchAarch64" "$pkg/Sources/TarwinTime"; do
  name=$(basename "$src")
  "$bin/swiftc" "${flags[@]}" -emit-module -module-name "$name" -emit-module-path "$d/$name.swiftmodule" "$src"/*.swift
done
"$bin/swiftc" "${flags[@]}" -emit-ir "$here/Probe.swift" "$here/../SMPClock.swift" "$pkg/../tarboot/tests/FirmwareProbe/Memory.swift" -o "$d/probe.ll"
"$bin/clang" -target "$t" -mstrict-align -Oz -ffunction-sections -fdata-sections -c "$d/probe.ll" -o "$d/probe.o"
for src in "$here/Boot" "$pkg/tools/ArmCounter" "$pkg/../tarwin-arch-aarch64/tools/PSCI"; do
  obj="$d/$(basename "$src")"
  swift "$src.swift" > "$obj.S"
  "$bin/clang" -target "$t" -c "$obj.S" -o "$obj.o"
done
printf '%s\n' 'ENTRY(_start)' 'SECTIONS { . = 0x40080000; .text : { *(.text.boot) *(.text*) *(.rodata*) } .bss : { *(.bss*) } }' > "$d/layout"
"$bin/ld.lld" --gc-sections -T "$d/layout" "$d"/*.o -o "$d/guest.elf"
"$bin/llvm-objcopy" -O binary "$d/guest.elf" "$d/guest.bin"
m=virt-11.1,gic-version=3,secure=off,virtualization=on
args=(-cpu max -accel tcg -smp 2 -m 128M -nodefaults -nographic -serial none -monitor none)
qemu-system-aarch64 -machine "$m,dumpdtb=$d/virt.dtb" "${args[@]}"
[[ $(fdtget "$d/virt.dtb" /psci method) == smc &&
   $(fdtget "$d/virt.dtb" /cpus/cpu@0 enable-method) == psci &&
   $(fdtget "$d/virt.dtb" /cpus/cpu@1 enable-method) == psci &&
   $(fdtget -t x "$d/virt.dtb" /pl031@9010000 reg) == '0 9010000 0 1000' &&
   $(fdtget "$d/virt.dtb" /pl031@9010000 compatible) == 'arm,pl031 arm,primecell' ]]
run() { python3 -c 'import subprocess,sys; sys.exit(subprocess.run(sys.argv[1:],timeout=15).returncode)' \
  qemu-system-aarch64 -machine "$m" "${args[@]}" -rtc clock=vm -dtb "$d/virt.dtb" \
  -kernel "$d/guest.bin" -semihosting-config enable=on,target=native -d int -D "$d/int" \
  >"$d/log" 2>&1 || { cat "$d/log"; tail -20 "$d/int"; exit 1; }; }
run
grep -Fx 'ARM-EL2-PSCI-TWO-CPU-PL031-CLOCK-PAGE-AND-OFF' "$d/log"
fdtput -t s "$d/virt.dtb" /cpus/cpu@1 enable-method spin-table
run
grep -Fx 'ARM-UNSUPPORTED-FIRMWARE-CPU-START-REFUSED' "$d/log"
