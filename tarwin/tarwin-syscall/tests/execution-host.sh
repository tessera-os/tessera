#!/bin/sh
# Host behavior tests; optionally cross-compile non-allocating Embedded
# objects. Neither stage is a kernel image, boot, or §34 performance run.
set -eu
tarwin=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for pkg in object syscall sched sync ipc loader security; do
    "${SWIFT:-swift}" test --package-path "$tarwin/tarwin-$pkg" --scratch-path "${SWIFT_TEST_CACHE:-$out}/build-$pkg"
    if [ -n "${EMBEDDED_SWIFTC:-}" ]; then
        for src in "$tarwin/tarwin-$pkg"/Sources/Tarwin*; do
            for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
                "$EMBEDDED_SWIFTC" -enable-experimental-feature Embedded -no-allocations -wmo -O \
                    -target "$target" -parse-as-library -module-name "$(basename "$src")" \
                    -c "$src"/*.swift -o "$out/$pkg-$target.o"
                echo "Embedded compile only: $pkg ($target)"
            done
        done
    fi
done
