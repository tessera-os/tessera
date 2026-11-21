#!/bin/sh
# Host behavior tests; optionally cross-compile non-allocating Embedded
# objects. Neither stage is a kernel image, boot, or §34 performance run.
set -eu
tarwin=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
native="$tarwin/../libtessera/app/Backend/Tarwin"
compile() {
    module=$1; target=$2; shift 2
    dir="$out/$target"
    mkdir -p "$dir"
    "$EMBEDDED_SWIFTC" -enable-experimental-feature Embedded -no-allocations -wmo -O \
        -target "$target" -parse-as-library -module-name "$module" -I "$dir" \
        -emit-module -emit-module-path "$dir/$module.swiftmodule" -emit-object -o "$dir/$module.o" "$@"
    echo "Embedded compile only: $module ($target)"
}
for pkg in syscall object sched sync ipc loader security; do
    "${SWIFT:-swift}" test --package-path "$tarwin/tarwin-$pkg" --scratch-path "${SWIFT_TEST_CACHE:-$out}/build-$pkg"
    if [ -n "${EMBEDDED_SWIFTC:-}" ]; then
        for src in "$tarwin/tarwin-$pkg"/Sources/Tarwin*; do
            for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
                compile "$(basename "$src")" "$target" "$src"/*.swift
            done
        done
    fi
done
"${SWIFT:-swift}" test --package-path "$native" --scratch-path "${SWIFT_TEST_CACHE:-$out}/build-native"
if [ -n "${EMBEDDED_SWIFTC:-}" ]; then
    sh "$tarwin/tarwin-sched/tests/bootstrap-stack.sh"
    for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
        compile LibTesseraTarwin "$target" "$native"/CallNumbers.swift "$native"/NativeEntry.swift "$native"/NativeHandles.swift
    done
fi
