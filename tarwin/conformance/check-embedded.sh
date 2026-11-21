#!/bin/sh
# Compile the freestanding components, including the actual shared call table.
# This does not link a kernel, run a guest, or establish physical conformance.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
compiler=${SWIFTC:-swiftc}
for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
    dir="$out/$target"
    mkdir "$dir"
    set -- -target "$target" -wmo -O -no-allocations -parse-as-library -enable-experimental-feature Embedded
    "$compiler" "$@" -module-name TarwinSyscall -emit-module -emit-module-path "$dir/TarwinSyscall.swiftmodule" \
        "$root"/tarwin-syscall/Sources/TarwinSyscall/*.swift
    for path in tarwin-hv/Sources/TarwinHV tarwin-probe/Sources/TarwinProbe tarwin-trace/Sources/TarwinTrace \
        tarwin-trace/debug-image/Sources/TarwinDebugImage; do
        module=${path##*/}
        "$compiler" "$@" -module-name "$module" -I "$dir" -c "$root/$path"/*.swift -o "$dir/$module.o"
    done
    echo "Compiled kernel components: $target"
done
