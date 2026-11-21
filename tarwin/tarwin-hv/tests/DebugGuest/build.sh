#!/bin/sh
# Compile the guest independently of the monitor. No TarwinHV imports or
# host symbols: the only communication is through mapped frames and an exit.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
t=$(cd "$here/../../.." && pwd)
out=$1
target=$2
arch=$3
march=$4
tc=$5
shift 5
dir="$out/guest"
mkdir "$dir"
set -- "$@" -target "$target" -wmo -Osize -no-allocations -parse-as-library -enable-experimental-feature Embedded -Xfrontend -disable-stack-protector -Xfrontend -function-sections -Xllvm -vectorize-loops=false -Xllvm -vectorize-slp=false -I "$dir"
for src in "$t"/kcore/Sources/KCore "$t"/tarwin-time/Sources/TarwinTime "$t"/tarwin-sched/Sources/TarwinSched "$t"/tarwin-mm/Sources/TarwinMM "$t"/tarwin-boot/Sources/TarwinBoot "$t/../tessera/build/tarwin/Sources/TarwinBootstrap"; do
  module=${src##*/}
  "$tc/swiftc" "$@" -module-name "$module" -emit-module -emit-module-path "$dir/$module.swiftmodule" "$src/"*.swift
done
"$tc/swift" "$here/GuestEntry.swift" "$arch" > "$dir/start.s"
"$tc/clang" -target "$target" -march="$march" -c "$dir/start.s" -o "$dir/entry.o"
"$tc/swiftc" "$@" -module-name TarwinDebugGuest -c "$here/Kernel.swift" "$t/tarboot/tests/FirmwareProbe/Memory.swift" -o "$dir/kernel.o"
"$tc/ld.lld" -T "$here/kernel.ld" --gc-sections -o "$dir/kernel.elf" "$dir/entry.o" "$dir/kernel.o"
"$tc/llvm-objcopy" -O binary "$dir/kernel.elf" "$dir/kernel.bin"
if [ -n "${GUEST_ELF_DIR:-}" ]; then mkdir -p "$GUEST_ELF_DIR"; cp "$dir/kernel.elf" "$GUEST_ELF_DIR/$arch.elf"; fi
"$tc/swift" "$here/Pack.swift" "$arch" "$dir/kernel.bin"
