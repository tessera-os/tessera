#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tc=${SWIFT_TOOLCHAIN:-/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin}
share=${BOCHS_SHARE:-$(brew --prefix bochs)/share/bochs}
out=$(mktemp -d)
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi; if [ -n "${CAPTURE_DIR:-}" ]; then mkdir -p "$CAPTURE_DIR"; cp "$out/bochs.log" "$out/serial.txt" "$CAPTURE_DIR" 2>/dev/null || :; fi; rm -rf "$out"' EXIT
trap 'exit 1' INT TERM
VMX_IMAGE="$out/monitor.elf" sh "$here/../StageTwoHarness/run.sh" vmx-build
entry=$("$tc/llvm-nm" "$out/monitor.elf" | awk '$3 == "_start" {print $1}')
"$tc/llvm-objcopy" -O binary "$out/monitor.elf" "$out/monitor"
"$tc/swift" "$here/BochsBoot.swift" "$entry" "$(wc -c < "$out/monitor" | tr -d ' ')" > "$out/boot.s"
"$tc/clang" -target i386-none-none-elf -c "$out/boot.s" -o "$out/boot.o"
"$tc/ld.lld" -m elf_i386 --image-base 0 -Ttext 0x7c00 -e boot --oformat binary "$out/boot.o" -o "$out/sector"
dd if=/dev/zero of="$out/boot.img" bs=512 count=2880 2>/dev/null
dd if="$out/sector" of="$out/boot.img" conv=notrunc 2>/dev/null
dd if="$out/monitor" of="$out/boot.img" bs=512 seek=1 conv=notrunc 2>/dev/null
cat > "$out/config" <<EOF
megs: 32
romimage: file="$share/BIOS-bochs-latest"
vgaromimage: file="$share/VGABIOS-lgpl-latest.bin"
display_library: nogui
cpu: model=corei7_skylake_x, count=1, ips=50000000, reset_on_triple_fault=0
floppya: 1_44="$out/boot.img", status=inserted
boot: floppy
com1: enabled=1, mode=file, dev="$out/serial.txt"
log: $out/bochs.log
panic: action=fatal
clock: sync=none
EOF
bochs -q -f "$out/config" </dev/null > "$out/console" 2>&1 &
pid=$!
for i in $(seq 1 300); do
  if grep -Fqx 'TARWIN X64 EPT PASS' "$out/serial.txt" 2>/dev/null; then
    echo 'Bochs: TARWIN X64 EPT PASS (emulation only)'
    exit 0
  fi
  if grep -Eq 'TARWIN .* FAIL|VMX UNAVAILABLE' "$out/serial.txt" 2>/dev/null || ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 0.1
done
cat "$out/serial.txt" >&2 || :
tail -35 "$out/bochs.log" "$out/console" >&2
exit 1
