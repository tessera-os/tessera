#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pkgs=$(cd "$here/../../../.." && pwd)
arch="$pkgs/tarwin/tarwin-arch-aarch64/Sources/TarwinArchAarch64"
bin=$(dirname "${EMBEDDED_SWIFTC:?macOS Swift toolchain with Embedded modules required}")
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
swiftc "$arch"/*.swift "$pkgs/tessera/build/tarwin-stage0"/{ArmHostTrap,ArmGuardedSlice}.swift -o "$d/emit"
"$d/emit" > "$d/host.S"
swift "$here/HostProbe.swift" > "$d/start.S"
swift "$here/EL0SliceProbe.swift" > "$d/slice.inc"
flags=(-target aarch64-none-none-elf -enable-experimental-feature Embedded -no-allocations
       -enable-experimental-feature Extern -swift-version 6 -Osize -wmo -parse-as-library
       -Xfrontend -disable-stack-protector -Xcc -mgeneral-regs-only -Xcc -mbranch-protection=bti -I "$d")
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
run_guest() {
  # Bound a guest whose unhandled exception correctly stops the boot CPU.
  local board=virt extra=()
  if [[ $1 == genid* ]]; then
    board=virt-11.1
    extra=(-global fw_cfg_mem.dma_enabled=off)
    if [[ ${2:-} != absent ]]; then extra+=(-device tarwin-virt-vmgenid-ro); fi
  fi
  python3 -c 'import subprocess,sys; sys.exit(subprocess.run(sys.argv[1:], timeout=10).returncode)' qemu-system-aarch64 -machine "$board,virtualization=on" \
    -cpu max -smp 1 -m 128M -nodefaults -nographic -monitor none -serial none \
    ${extra[@]+"${extra[@]}"} \
    -semihosting-config enable=on,target=native -d int -D "$d/exceptions" -kernel "$d/$1.elf" >"$d/log" 2>&1 || {
      cat "$d/log" >&2; exit 1
    }
}
run_guest probe
grep -Fx 'VHE-COPY-READ-WRITE-ABORT-DENY' "$d/log"
grep -Fx 'VHE-HIGH-HOST-PRIVATE-ROOT-SWITCH' "$d/log"
grep -Fx 'VHE-IMPORT-IA-HOST-KEY-RESTORED' "$d/log"
grep -Fx 'VHE-STOP-ON-SEPARATE-SCHEDULER-STACK' "$d/log"
grep -Ex 'VHE-CPU-GCS-S1PIE-TCRX=[0-9a-f]{3}' "$d/log"
if grep -Fxq 'VHE-CPU-GCS-S1PIE-TCRX=111' "$d/log"; then
  "$bin/swiftc" "${flags[@]}" -D TEST_GCS -emit-ir "$here/Probe.swift" "$here/../FirmwareProbe/Memory.swift" -o "$d/gcs.ll"
  "$bin/clang" -target aarch64-none-none-elf -ffunction-sections -fdata-sections -Oz -c "$d/gcs.ll" -o "$d/gcs-probe.o"
  "$bin/clang" -target aarch64-none-none-elf -march=armv9.4-a+gcs -DTEST_GCS -c "$d/start.S" -o "$d/gcs.o"
  "$bin/ld.lld" --gc-sections -T "$d/sections" "$d/gcs.o" "$d/host.o" "$d/gcs-probe.o" -o "$d/gcs.elf"
  run_guest gcs
  grep -Fx 'VHE-GCS-STORE-ORDINARY-WRITE-DENIED' "$d/log"
  grep -Fx 'VHE-PRIVATE-PIE-RELRO-GUARD' "$d/log"
  grep -Fx 'VHE-FIRST-GCS-REGS-RESTORED' "$d/log"
  if [[ ${TARBOOT_TEST_RO_GENID:-0} == 1 ]]; then
    for src in "$pkgs/tarwin/kcore/Sources/KCore" "$pkgs/tarwin/tarwin-boot/Sources/TarwinBoot" \
      "$pkgs/tarwin/tarboot/Sources/Tarboot" "$pkgs/tarwin/tarwin-security/random/Sources/TarwinRandomCore" \
      "$pkgs/tessera/build/tarwin/Sources/TarwinW1Generation"; do
      mod=$(basename "$src")
      "$bin/swiftc" "${flags[@]}" -enable-experimental-feature Volatile -module-name "$mod" \
        -emit-module -emit-module-path "$d/$mod.swiftmodule" "$src"/*.swift
    done
    swift "$pkgs/tessera/build/tarwin-stage0/ArmFIFOAccess.swift" > "$d/device.ll"
    "$bin/clang" -target aarch64-none-none-elf -Oz -c "$d/device.ll" -o "$d/device.o"
    "$bin/swiftc" "${flags[@]}" -D TEST_GCS -D TEST_HIGH_GENID -emit-ir \
      "$here/Probe.swift" "$here/GenerationProbe.swift" "$here/../FirmwareProbe/Memory.swift" \
      "$pkgs/tessera/build/tarwin/Sources/TarwinW1Bootstrap/KernelGeneration.swift" -o "$d/genid.ll"
    "$bin/clang" -target aarch64-none-none-elf -ffunction-sections -fdata-sections -Oz -c "$d/genid.ll" -o "$d/genid-probe.o"
    "$bin/clang" -target aarch64-none-none-elf -march=armv9.4-a+gcs -DTEST_GCS -DTEST_HIGH_GENID -c "$d/start.S" -o "$d/genid.o"
    "$bin/ld.lld" --gc-sections -T "$d/sections" "$d/genid.o" "$d/device.o" "$d/host.o" "$d/genid-probe.o" -o "$d/genid.elf"
    run_guest genid
    grep -Fx 'VHE-VMGEN-KERNEL-READONLY-NO-IDENTITY-OR-USER-ACCESS' "$d/log"
    run_guest genid absent
    grep -Fx 'VHE-VMGEN-ABSENT-NO-MMIO-OR-EL0' "$d/log"
    if grep -Fq 'Exception return from AArch64 EL2 to AArch64 EL0' "$d/exceptions"; then exit 1; fi
  fi
  for mod in TarwinABI TarwinSyscall; do
    "$bin/swiftc" "${flags[@]}" -module-name "$mod" -emit-module -emit-module-path "$d/$mod.swiftmodule" \
      "$pkgs/tarwin/tarwin-syscall/Sources/$mod"/*.swift
  done
  "$bin/swiftc" "${flags[@]}" -emit-ir "$pkgs/tessera/build/tarwin/Sources/TarwinW1Bootstrap/TrapDispatch.swift" \
    "$here/TrapProbe.swift" -o "$d/dispatch.ll"
  "$bin/clang" -target aarch64-none-none-elf -ffunction-sections -fdata-sections -Oz -c "$d/dispatch.ll" -o "$d/dispatch.o"
  slice=slice
  slice_flags=()
  slice_objects=("$d/gcs-probe.o")
  if [[ ${TARBOOT_TEST_RO_GENID:-0} == 1 ]]; then
    slice=genid-slice
    slice_flags=(-DTEST_HIGH_GENID)
    slice_objects=("$d/genid-probe.o" "$d/device.o")
  fi
  "$bin/clang" -target aarch64-none-none-elf -march=armv9.4-a+gcs -DTEST_GCS -DTEST_SLICE \
    ${slice_flags[@]+"${slice_flags[@]}"} -I "$d" -c "$d/start.S" -o "$d/slice.o"
  "$bin/ld.lld" --gc-sections -T "$d/sections" "$d/slice.o" "$d/host.o" "${slice_objects[@]}" "$d/dispatch.o" -o "$d/$slice.elf"
  run_guest "$slice"
  grep -Fx 'Exception return from AArch64 EL2 to AArch64 EL0 PC 0x100010000' "$d/exceptions"
  [[ $(grep -Fc 'Exception return from AArch64 EL2 to AArch64 EL0 PC ' "$d/exceptions") == 2 &&
     $(grep -Fc '...from EL0 to EL2' "$d/exceptions") == 2 &&
     $(grep -Fc '...with ESR 0x15/0x56000000' "$d/exceptions") == 2 ]]
  grep -Fx 'VHE-EL0-SVC-HOST-KEYS-AND-ROOT-RESTORED' "$d/log"
  if [[ ${TARBOOT_TEST_PROCESS_CURRENT:-0} == 1 ]]; then
    bash "$pkgs/libtessera/app/Backend/Tarwin/tests/w1-framework-body.sh" "$d/body.o"
    cat > "$d/body.ld" <<'LD'
ENTRY(libtessera_tarwin_process_current_body)
SECTIONS {
  . = 0x100014000;
  .text : { *(.text.libtessera_tarwin_process_current_body) *(.text*) *(.rodata*) }
  ASSERT(libtessera_tarwin_process_current_body == 0x100014000, "unexpected library entry")
  ASSERT(SIZEOF(.text) <= 16384, "diagnostic RX page overflow")
  .data : { *(.data*) *(.bss*) }
  ASSERT(SIZEOF(.data) == 0, "user body must not need writable globals")
}
LD
    "$bin/ld.lld" --gc-sections -T "$d/body.ld" "$d/body.o" -o "$d/body.elf"
    "$bin/llvm-objcopy" -O binary --only-section=.text "$d/body.elf" "$d/process-body.bin"
    "$bin/swiftc" "${flags[@]}" -module-name TarwinObject -emit-module -emit-module-path "$d/TarwinObject.swiftmodule" \
      "$pkgs/tarwin/tarwin-object/Sources/TarwinObject"/*.swift
    "$bin/swiftc" "${flags[@]}" -D TEST_GCS -D TEST_PROCESS -emit-ir \
      "$here/"{Probe,ProcessProbe,ExitProbe}.swift "$here/../FirmwareProbe/Memory.swift" \
      "$pkgs/tessera/build/tarwin/Sources/TarwinW1Bootstrap/"{TrapDispatch,TrapFramePage,StopCaller}.swift \
      "$pkgs/tarwin/tarwin-syscall/providers/Sources/TarwinObjectCalls/"{ProcessCurrentCalls,ProcessExitCalls}.swift -o "$d/process.ll"
    "$bin/clang" -target aarch64-none-none-elf -mno-outline-atomics -ffunction-sections -fdata-sections -Oz \
      -c "$d/process.ll" -o "$d/process.o"
    "$bin/clang" -target aarch64-none-none-elf -march=armv9.4-a+gcs -DTEST_GCS -DTEST_PROCESS -DTEST_SLICE \
      -I "$d" -c "$d/start.S" -o "$d/process-start.o"
    "$bin/ld.lld" --gc-sections -T "$d/sections" "$d/process-start.o" "$d/host.o" "$d/process.o" -o "$d/current.elf"
    run_guest current
    grep -Fx 'VHE-EL0-LIBTESSERA-SELF-HANDLE-BAD-ORIGIN-STOPPED' "$d/log"
    [[ $(grep -Fc 'Exception return from AArch64 EL2 to AArch64 EL0 PC ' "$d/exceptions") == 2 &&
       $(grep -Fc '...from EL0 to EL2' "$d/exceptions") == 2 &&
       $(grep -Fc '...with ESR 0x15/0x56000000' "$d/exceptions") == 2 ]]
    "$bin/clang" -target aarch64-none-none-elf -march=armv9.4-a+gcs -DTEST_GCS -DTEST_PROCESS -DTEST_EXIT -DTEST_SLICE \
      -I "$d" -c "$d/start.S" -o "$d/exit-start.o"
    "$bin/ld.lld" --gc-sections -T "$d/sections" "$d/exit-start.o" "$d/host.o" "$d/process.o" -o "$d/exit.elf"
    run_guest exit
    grep -Fx 'VHE-EL0-EXIT-ACKNOWLEDGED-ON-SCHEDULER-STACK' "$d/log"
    [[ $(grep -Fc 'Exception return from AArch64 EL2 to AArch64 EL0 PC ' "$d/exceptions") == 1 &&
       $(grep -Fc '...from EL0 to EL2' "$d/exceptions") == 1 &&
       $(grep -Fc '...with ESR 0x15/0x56000000' "$d/exceptions") == 1 ]]
  fi
  if [[ ${TARBOOT_TEST_TIME_PAGE:-0} == 1 ]]; then
    timepkg="$pkgs/tarwin/tarwin-time"
    "$bin/swiftc" "${flags[@]}" -module-name TarwinTime -emit-module -emit-module-path "$d/TarwinTime.swiftmodule" \
      "$timepkg/Sources/TarwinTime"/*.swift
    swift "$timepkg/tools/ArmCounter.swift" > "$d/counter.S"
    "$bin/clang" -target aarch64-none-none-elf -c "$d/counter.S" -o "$d/counter.o"
    for part in reader publisher; do
      if [[ $part == reader ]]; then files=(-D CLOCK_READER)
      else files=(-D TEST_TIME_PAGE -D TEST_GCS "$here/Probe.swift" "$pkgs/tessera/build/tarwin/Sources/TarwinW1Bootstrap/ClockPage.swift"); fi
      "$bin/swiftc" "${flags[@]}" "${files[@]}" -emit-ir "$here/ClockProbe.swift" "$here/../FirmwareProbe/Memory.swift" -o "$d/$part.ll"
      "$bin/clang" -target aarch64-none-none-elf -ffunction-sections -fdata-sections -Oz -c "$d/$part.ll" -o "$d/$part.o"
    done
    cat > "$d/reader.ld" <<'LD'
ENTRY(tarwin_test_clock_read)
SECTIONS {
  . = 0x100011000;
  .text : { *(.text.tarwin_test_clock_read) *(.text*) *(.rodata*) }
  ASSERT(tarwin_test_clock_read == 0x100011000, "reader entry")
  ASSERT(. <= 0x100014000, "reader exceeds RX page")
  .data : { *(.data*) *(.bss*) }
  ASSERT(SIZEOF(.data) == 0, "user reader must have no writable globals")
}
LD
    "$bin/ld.lld" --gc-sections -T "$d/reader.ld" "$d/reader.o" "$d/counter.o" -o "$d/reader.elf"
    "$bin/llvm-objcopy" -O binary --only-section=.text "$d/reader.elf" "$d/reader.bin"
    for mode in clock-ro clock-el0; do
      opts=()
      if [[ $mode == clock-el0 ]]; then opts=(-DTEST_SLICE); fi
      "$bin/clang" -target aarch64-none-none-elf -march=armv9.4-a+gcs -DTEST_GCS -DTEST_TIME_PAGE \
        ${opts[@]+"${opts[@]}"} -I "$d" -c "$d/start.S" -o "$d/clock-start.o"
      "$bin/ld.lld" --gc-sections -T "$d/sections" "$d/clock-start.o" "$d/host.o" "$d/publisher.o" \
        "$d/counter.o" "$d/dispatch.o" -o "$d/$mode.elf"
      run_guest "$mode"
      if [[ $mode == clock-el0 ]]; then
        grep -Fx 'VHE-EL0-SHARED-CLOCK-READ' "$d/log"
        grep -Fx 'VHE-EL0-SMEARED-UTC-AND-KERNEL-UPDATE' "$d/log"
        grep -Fx 'VHE-THREAD-PROCESS-CPU-TWO-RUNS-NO-HOST-GAP' "$d/log"
        [[ $(grep -Fc '...from EL0 to EL2' "$d/exceptions") == 2 ]]
      else grep -Fx 'VHE-TIME-PAGE-EL0-RO' "$d/log"; fi
    done
  fi
  "$bin/clang" -target aarch64-none-none-elf -march=armv9.4-a+gcs -DTEST_GCS -DTEST_WRONG_BANK -c "$d/start.S" -o "$d/wrong.o"
  "$bin/ld.lld" --gc-sections -T "$d/sections" "$d/wrong.o" "$d/host.o" "$d/gcs-probe.o" -o "$d/wrong.elf"
  run_guest wrong
  grep -Fx 'VHE-REFUSED-MISMATCHED-PIE-BANK' "$d/log"
elif [[ ${TARBOOT_TEST_RO_GENID:-0} == 1 || ${TARBOOT_TEST_TIME_PAGE:-0} == 1 || ${TARBOOT_TEST_PROCESS_CURRENT:-0} == 1 ]]; then
  echo 'requested guarded diagnostic requires GCS, S1PIE and TCRX' >&2
  exit 1
fi
