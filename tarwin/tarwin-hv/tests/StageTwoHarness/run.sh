#!/bin/sh
set -eu
support=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
hv=$(cd "$support/../.." && pwd)
tc=${SWIFT_TOOLCHAIN:-/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin}
out=$(mktemp -d)
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi; rm -rf "$out"' EXIT
trap 'exit 1' INT TERM
isa=$1
profile=${2:-probe}
case "$isa:$profile" in arm:irq|rv64:irq|arm:kernel|rv64:kernel|x64:kernel|arm:metal|rv64:metal|x64:metal|*:probe) ;; *) exit 2;; esac
rvMachine=virt
case "$isa" in
  arm)
    here="$hv/tests/ArmStageTwoProbe"
    arch=aarch64-none-none-elf
    march=armv8.2-a
    pass='TARWIN EL2 STAGE2 PASS'
    set -- -Xcc -mgeneral-regs-only -Xcc -mstrict-align
    ;;
  rv64)
    here="$hv/tests/RVStageTwoProbe"
    arch=riscv64-none-none-eabi
    march=rv64imah_zicsr_zifencei
    pass='TARWIN RV64 GSTAGE PASS'
    set -- -Xcc -mcmodel=medany
    ;;
  x64|vmx-build)
    mode=$1
    here="$hv/tests/X64StageTwoProbe"
    arch=x86_64-unknown-none-elf
    march=x86-64
    pass='TARWIN X64 NPT PASS'
    set -- -Xcc -mno-red-zone -Xcc -mno-sse -Xcc -mno-sse2
    ;;
  *) exit 2 ;;
esac
if [ "$profile" = kernel ] || [ "$profile" = metal ]; then
  pass="TARWIN DEBUG CONSOLE PASS"
  "$tc/swift" "$here/Image.swift" kernel > "$out/entry.s"
  GUEST_PROFILE="$profile" sh "$hv/tests/DebugGuest/build.sh" "$out" "$arch" "$isa" "$march" "$tc" "$@" >> "$out/entry.s"
elif [ "$profile" = irq ]; then
  pass="TARWIN $isa IRQ TIMER PASS"
  rvMachine="virt,aia=aplic-imsic,aia-guests=1"
  "$tc/swift" "$here/Image.swift" irq > "$out/entry.s"
  "$tc/swift" "$hv/tests/InterruptProbe/$isa.swift" >> "$out/entry.s"
elif [ "${mode:-}" = vmx-build ]; then
  "$tc/swift" "$here/Image.swift" vmx > "$out/entry.s"
  "$tc/swift" "$hv/tests/VMXStageTwoProbe/Instructions.swift" >> "$out/entry.s"
else
  "$tc/swift" "$here/Image.swift" > "$out/entry.s"
fi
"$tc/clang" -target "$arch" -march="$march" -c "$out/entry.s" -o "$out/entry.o"
set -- "$@" -target "$arch" -wmo -O -no-allocations -parse-as-library -enable-experimental-feature Embedded -Xfrontend -disable-stack-protector -Xfrontend -function-sections
for module in TarwinABI TarwinSyscall; do
  "$tc/swiftc" "$@" -module-name "$module" -I "$out" -emit-module -emit-module-path "$out/$module.swiftmodule" -c "$hv/../tarwin-syscall/Sources/$module/"*.swift -o "$out/$module.o"
done
probe="$here/Probe.swift"
if [ "$profile" = irq ]; then probe="$hv/tests/InterruptProbe/Monitor.swift"; fi
if [ "$profile" = kernel ] || [ "$profile" = metal ]; then probe="$hv/tests/DebugGuest/Monitor.swift"; fi
if [ "$profile" = metal ]; then set -- "$@" -D METAL_GUEST; fi
if [ "${mode:-}" = vmx-build ]; then probe="$hv/tests/VMXStageTwoProbe/Probe.swift"; fi
"$tc/swiftc" "$@" -module-name GuestStageTwoProbe -I "$out" -c "$hv/Sources/TarwinHV/"*.swift "$support/Memory.swift" "$support/SVM.swift" "$support/WriteTracking.swift" "$probe" -o "$out/probe.o"
"$tc/ld.lld" -T "$here/probe.ld" --gc-sections -o "$out/probe.elf" "$out/"*.o
if [ "${mode:-}" = vmx-build ]; then
  if [ -n "${VMX_IMAGE:-}" ]; then cp "$out/probe.elf" "$VMX_IMAGE"; fi
  echo "Linked Intel VMX/EPT diagnostic; execution NOT VERIFIED"
  exit 0
fi
set -- -accel tcg -smp 1 -m 128 -display none -nodefaults -monitor none -no-reboot -kernel "$out/probe.elf"
if [ "$profile" = metal ]; then
  : "${METAL_CHECK:?run conformance/check-metal-guest.sh}"
  set -- "$@" -chardev "socket,id=debug,path=$out/uart,server=on,wait=on" -serial chardev:debug
else
  set -- "$@" -serial "file:$out/uart"
fi
case "$arch" in
  aarch64*) qemu-system-aarch64 "$@" -machine virt,virtualization=on,gic-version=3 -cpu max > "$out/qemu.log" 2>&1 & ;;
  riscv64*) qemu-system-riscv64 "$@" -machine "$rvMachine" -cpu rv64,h=true > "$out/qemu.log" 2>&1 & ;;
  x86_64*) qemu-system-x86_64 "$@" -machine q35 -cpu max,vendor=AuthenticAMD,svm=on,npt=on > "$out/qemu.log" 2>&1 & ;;
esac
pid=$!
if [ "$profile" = metal ]; then
  python3 "$hv/../conformance/metal-integration/connect.py" "$out/uart" "$METAL_CHECK" > "$out/report" 2>&1 || {
    cat "$out/report" "$out/qemu.log" >&2; exit 1;
  }
  cat "$out/report"
  if [ -n "${CAPTURE_DIR:-}" ]; then mkdir -p "$CAPTURE_DIR"; cp "$out/report" "$CAPTURE_DIR/$isa-metal.log"; fi
  exit 0
fi
for i in $(seq 1 100); do
  if grep -Fqx "$pass" "$out/uart" 2>/dev/null; then
    if [ "$profile" = kernel ]; then
      printf '%s\n' 'TARWIN DEBUG GUEST' 'MEMORY ONLINE' 'BOOT CPU ONLINE' "$pass" > "$out/expected"
      tail -4 "$out/uart" > "$out/result"
      diff -u "$out/expected" "$out/result"
      cat "$out/result"
    else echo "$pass"; fi
    if [ -n "${CAPTURE_DIR:-}" ]; then
      mkdir -p "$CAPTURE_DIR"
      cp "$out/uart" "$CAPTURE_DIR/$isa-$profile.uart"
    fi
    exit 0
  fi
  if grep -q 'TARWIN .* FAIL' "$out/uart" 2>/dev/null || ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 0.1
done
cat "$out/qemu.log" "$out/uart" >&2
exit 1
