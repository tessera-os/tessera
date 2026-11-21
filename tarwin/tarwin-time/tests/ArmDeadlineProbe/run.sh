#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pkg=$(cd "$here/../.." && pwd)
bin=$(dirname "${EMBEDDED_SWIFTC:?Embedded Swift toolchain required}")
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
flags=(-target aarch64-none-none-elf -enable-experimental-feature Embedded -no-allocations
       -enable-experimental-feature Extern -enable-experimental-feature Volatile -swift-version 6
       -Osize -wmo -parse-as-library -Xfrontend -disable-stack-protector -Xcc -mgeneral-regs-only)
mode=timer
if [[ ${ARM_WATCHDOG:-0} == 1 ]]; then
  mode=watchdog
  flags+=(-D ARM_WATCHDOG -Xcc -mstrict-align)
  for src in "$pkg/../kcore/Sources/KCore" "$pkg/../tarwin-boot/Sources/TarwinBoot" \
    "$pkg/../tarwin-arch-aarch64/Sources/TarwinArchAarch64"; do
    name=$(basename "$src")
    "$bin/swiftc" "${flags[@]}" -I "$d" -emit-module -module-name "$name" -emit-module-path "$d/$name.swiftmodule" "$src"/*.swift
  done
fi
"$bin/swiftc" "${flags[@]}" -emit-module -module-name TarwinTime -emit-module-path "$d/TarwinTime.swiftmodule" \
  "$pkg/Sources/TarwinTime"/*.swift
for src in "$pkg/../tarwin-sched/Sources/TarwinSched" "$pkg/../../tessera/build/tarwin/Sources/TarwinBootstrap"; do
  name=$(basename "$src")
  "$bin/swiftc" "${flags[@]}" -I "$d" -module-name "$name" -emit-module -emit-module-path "$d/$name.swiftmodule" "$src"/*.swift
done
"$bin/swiftc" "${flags[@]}" -I "$d" -emit-ir "$here/Probe.swift" "$here/Watchdog.swift" "$here/../DeadlineDispatch.swift" "$pkg/../tarboot/tests/FirmwareProbe/Memory.swift" -o "$d/guest.ll"
"$bin/clang" -target aarch64-none-none-elf -ffunction-sections -fdata-sections -Oz -c "$d/guest.ll" -o "$d/guest.o"
for src in "$here/Boot" "$pkg/tools/ArmCounter" "$pkg/tools/ArmTimer"; do
  obj="$d/$(basename "$src")"
  swift "$src.swift" "$mode" > "$obj.S"
  "$bin/clang" -target aarch64-none-none-elf -c "$obj.S" -o "$obj.o"
done
printf '%s\n' 'ENTRY(_start)' 'SECTIONS { . = 0x40080000; .text : { *(.text.boot) *(.text*) *(.rodata*) } .bss : { *(.bss*) } }' > "$d/layout"
"$bin/ld.lld" --gc-sections -T "$d/layout" "$d"/*.o -o "$d/guest.elf"
m=virt-11.1,gic-version=3,secure=off,virtualization=off
cpu=(-cpu max)
image="$d/guest.elf"
if [[ $mode == watchdog ]]; then
  cpu=(-cpu max,cntfrq=1000000000 -device sbsa-gwdt,clock-frequency=1000000000 -action watchdog=reset
    -icount shift=4,align=off,sleep=off)
  qemu-system-aarch64 -machine "$m,dumpdtb=$d/virt.dtb" "${cpu[@]}" -smp 1 -m 128M -nodefaults -display none
  node=/watchdog@f001000
  [[ $(fdtget "$d/virt.dtb" "$node" compatible) == arm,sbsa-gwdt &&
     $(fdtget -t x "$d/virt.dtb" "$node" reg) == '0 f001000 0 1000 0 f000000 0 1000' ]]
  cpu+=(-dtb "$d/virt.dtb" -trace 'enable=sbsa_gwdt_*' -trace enable=watchdog_perform_action)
  image="$d/guest.bin"
  "$bin/llvm-objcopy" -O binary "$d/guest.elf" "$image"
fi
run() { python3 -c 'import subprocess,sys; sys.exit(subprocess.run(sys.argv[1:], timeout=10).returncode)' \
  qemu-system-aarch64 -machine "$m" "${cpu[@]}" \
  -accel tcg -smp 1 -m 128M -nodefaults -nographic -serial none -monitor none -kernel "$image" \
  -semihosting-config enable=on,target=native -d int -D "$d/int" >"$d/log" 2>&1 || { cat "$d/log"; tail -30 "$d/int"; exit 1; }; }
run
if [[ $mode == watchdog ]]; then
  grep -Fx ARM-WATCHDOG-DISPATCH-STOPPED "$d/log"
  grep -Fx ARM-WATCHDOG-RESET-AND-REENTRY "$d/log"
  [[ $(grep -c sbsa_gwdt_refresh_write "$d/int") == 9 ]]
  awk '/sbsa_gwdt_ws0_asserted/ {ws0++} /sbsa_gwdt_ws1_asserted/ && ws0 == 1 {ws1++}
    /watchdog_perform_action/ && ws1 == 1 {acted++} END {exit !(ws0 == 1 && ws1 == 1 && acted == 1)}' "$d/int"
  for invalid in overlapping absent; do
    if [[ $invalid == overlapping ]]; then
      fdtput -t x "$d/virt.dtb" "$node" reg 0 f001000 0 1000 0 f001000 0 1000
    else
      fdtput -r "$d/virt.dtb" "$node"
    fi
    run
    grep -Fx ARM-WATCHDOG-FIRMWARE-REFUSED "$d/log"
    if grep -Eq 'sbsa_gwdt_(control|refresh)_(read|write)' "$d/int"; then exit 1; fi
  done
else
  grep -Fx 'ARM-DEADLINE-PPI27-SLICE-AND-TICKLESS-IDLE' "$d/log"
  grep -Fx 'ARM-TWO-TIMERS-ONE-IRQ' "$d/log"
  [[ $(grep -Fc 'Taking exception 5 [IRQ]' "$d/int") == 3 ]]
fi
