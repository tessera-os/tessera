#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pkg=$(cd "$here/../.." && pwd)
bin=$(dirname "${EMBEDDED_SWIFTC:?Embedded Swift toolchain required}")
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
triple=riscv64-none-none-eabi
flags=(-target "$triple" -enable-experimental-feature Embedded -enable-experimental-feature Extern
  -enable-experimental-feature Volatile
  -no-allocations -Osize -wmo -parse-as-library -swift-version 6 -Xfrontend -disable-stack-protector -I "$d")
topology=none
modes=(single unsupported wrong-rate dual)
boot_arg=plic
if [[ ${AIA_RTC:-0} == 1 ]]; then
  flags+=(-D AIA_RTC)
  topology=aplic-imsic
  modes=(single no-ssaia wrong-controller)
  boot_arg=aia
fi
for src in "$pkg/../kcore/Sources/KCore" "$pkg/../tarwin-boot/Sources/TarwinBoot" "$pkg/../tarwin-arch-rv64/Sources/TarwinArchRv64" "$pkg/Sources/TarwinTime" \
  "$pkg/../tarwin-sched/Sources/TarwinSched" "$pkg/../../tessera/build/tarwin/Sources/TarwinBootstrap"; do
  name=$(basename "$src")
  "$bin/swiftc" "${flags[@]}" -module-name "$name" -emit-module -emit-module-path "$d/$name.swiftmodule" "$src"/*.swift
done
if [[ $topology == aplic-imsic ]]; then
  for src in "$pkg/../tarwin-ipc/Sources/TarwinIPC" "$pkg/../tarwin-device/Sources/TarwinIoCompletion"; do
    name=$(basename "$src")
    "$bin/swiftc" "${flags[@]}" -module-name "$name" -emit-module -emit-module-path "$d/$name.swiftmodule" "$src"/*.swift
  done
  irq="$pkg/../tarwin-device/Sources/TarwinDevice"
  "$bin/swiftc" "${flags[@]}" -module-name TarwinDevice -emit-module -emit-module-path "$d/TarwinDevice.swiftmodule" \
    "$irq/Interrupt.swift" "$irq/PortInterrupt.swift"
fi
"$bin/swiftc" "${flags[@]}" -emit-ir "$here/Probe.swift" "$here/IRQPort.swift" "$here/RTCSleep.swift" "$here/../SMPClock.swift" "$here/../DeadlineDispatch.swift" "$pkg/../tarboot/tests/FirmwareProbe/Memory.swift" -o "$d/probe.ll"
clangflags=(-target "$triple" -mcmodel=medany -msmall-data-limit=0 -mno-relax)
"$bin/clang" "${clangflags[@]}" -ffunction-sections -fdata-sections -Oz -c "$d/probe.ll" -o "$d/probe.o"
for src in "$here/Boot" "$pkg/tools/RvTimer" "$pkg/../tarwin-arch-rv64/tools/HSM" "$pkg/../tarwin-arch-rv64/tools/IMSIC"; do
  obj="$d/$(basename "$src")"
  swift "$src.swift" "$boot_arg" > "$obj.S"
  "$bin/clang" "${clangflags[@]}" -c "$obj.S" -o "$obj.o"
done
printf '%s\n' 'ENTRY(_start)' 'SECTIONS { . = 0x80200000; .text : { *(.text.boot) *(.text*) *(.rodata*) } .bss : { *(.bss*) } }' > "$d/layout"
"$bin/ld.lld" --no-relax --gc-sections -T "$d/layout" "$d"/*.o -o "$d/guest.elf"
for mode in "${modes[@]}"; do
  n=1; setting=on
  if [[ $mode == dual ]]; then n=2; elif [[ $mode == unsupported ]]; then setting=off; fi
  cpu=(-cpu "rv64,sstc=$setting" -accel tcg -smp "$n" -m 128M -nodefaults)
  qemu-system-riscv64 -machine "virt,aia=$topology,dumpdtb=$d/virt.dtb" "${cpu[@]}" -display none
  read_dt() { fdtget -t x "$d/virt.dtb" "$@"; }
  rtc=/soc/rtc@101000
  plic=/soc/interrupt-controller@c000000
  hart=$(read_dt /cpus/cpu@0/interrupt-controller phandle)
  [[ $(fdtget "$d/virt.dtb" "$rtc" compatible) == google,goldfish-rtc &&
     $(read_dt "$rtc" reg) == '0 101000 0 1000' ]]
  if [[ $topology == aplic-imsic ]]; then
    aplic=/soc/interrupt-controller@d000000
    imsic=/soc/interrupt-controller@28000000
    [[ $(read_dt "$rtc" interrupts) == 'b 4' &&
       $(read_dt "$rtc" interrupt-parent) == "$(read_dt "$aplic" phandle)" &&
       $(fdtget "$d/virt.dtb" "$aplic" compatible) == 'qemu,aplic riscv,aplic' &&
       $(read_dt "$aplic" reg) == '0 d000000 0 8000' &&
       $(read_dt "$aplic" riscv,num-sources) == 60 &&
       $(read_dt "$aplic" msi-parent) == "$(read_dt "$imsic" phandle)" &&
       $(fdtget "$d/virt.dtb" "$imsic" compatible) == 'qemu,imsics riscv,imsics' &&
       $(read_dt "$imsic" reg) == '0 28000000 0 1000' &&
       $(read_dt "$imsic" riscv,num-ids) == ff &&
       $(read_dt "$imsic" interrupts-extended) == "$hart 9" ]]
    if [[ $mode == no-ssaia ]]; then
      read -ra extensions <<< "$(fdtget "$d/virt.dtb" /cpus/cpu@0 riscv,isa-extensions)"
      kept=()
      for ext in "${extensions[@]}"; do if [[ $ext != ssaia ]]; then kept+=("$ext"); fi; done
      [[ ${#kept[@]} -lt ${#extensions[@]} ]]
      fdtput -t s "$d/virt.dtb" /cpus/cpu@0 riscv,isa-extensions "${kept[@]}"
    elif [[ $mode == wrong-controller ]]; then
      # Route the RTC to the *machine* controller in the guest tree only.
      fdtput -t x "$d/virt.dtb" "$rtc" interrupt-parent "$(read_dt /soc/interrupt-controller@c000000 phandle)"
    fi
  else
    [[ $(read_dt "$rtc" interrupts) == b &&
       $(read_dt "$rtc" interrupt-parent) == "$(read_dt "$plic" phandle)" &&
       $(read_dt "$plic" reg) == '0 c000000 0 600000' ]]
    if [[ $n == 1 ]]; then [[ $(read_dt "$plic" interrupts-extended) == "$hart b $hart 9" ]]; fi
  fi
  if [[ $mode == wrong-rate ]]; then
    freq=$(fdtget -t u "$d/virt.dtb" /cpus timebase-frequency)
    fdtput -t u "$d/virt.dtb" /cpus timebase-frequency "$((freq * 2))"
  fi
  python3 -c 'import subprocess,sys; sys.exit(subprocess.run(sys.argv[1:], timeout=10).returncode)' \
    qemu-system-riscv64 -machine "virt,aia=$topology" "${cpu[@]}" -dtb "$d/virt.dtb" -rtc clock=vm \
    -nographic -serial none -monitor none -bios default -kernel "$d/guest.elf" \
    -semihosting-config enable=on,target=native -d int -D "$d/int" >"$d/log" 2>&1 || { cat "$d/log"; tail -20 "$d/int"; exit 1; }
  if [[ $mode == no-ssaia ]]; then grep -Fx 'RV64-NO-SSAIA-REFUSED' "$d/log"
  elif [[ $mode == wrong-controller ]]; then grep -Fx 'RV64-INVALID-SUPERVISOR-IRQ-ROUTE-REFUSED' "$d/log"
  elif [[ $mode == dual ]]; then grep -Fx 'RV64-TWO-HART-CLOCK-RTC-CALIBRATION-PAGE-AND-STOP' "$d/log"
  elif [[ $mode == wrong-rate ]]; then grep -Fx 'RV64-WRONG-TIMEBASE-REFUSED' "$d/log"
  elif [[ $setting == on ]]; then grep -Fx 'RV64-SSTC-STIP-SLICE-AND-TICKLESS-IDLE' "$d/log"
    grep -Fx 'RV64-TWO-TIMERS-ONE-IRQ' "$d/log"
    grep -Fx 'RV64-RTC-WFI-WAKE-AND-DEFERRED-TIMER' "$d/log"
    if [[ $topology == aplic-imsic ]]; then
      grep -Fx 'RV64-APLIC-RTC-TO-SUPERVISOR-IMSIC-65' "$d/log"
      grep -Fx 'RV64-IRQ-PORT-MASKED-PENDING-REARM' "$d/log"
    fi
  else grep -Fx 'RV64-NO-SSTC-REFUSED' "$d/log"; fi
done
