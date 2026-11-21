#!/bin/sh
# Measure static frames, not high-water stack usage along a chain of calls.
set -eu
src=$(CDPATH= cd -- "$(dirname -- "$0")/../Sources/TarwinSched" && pwd)
swiftc=${EMBEDDED_SWIFTC:?set EMBEDDED_SWIFTC to a freestanding Swift compiler}
clang=${EMBEDDED_CLANG:-$(dirname "$(command -v "$swiftc")")/clang}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for arch in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
    "$swiftc" -target "$arch" -enable-experimental-feature Embedded -no-allocations \
        -wmo -Osize -parse-as-library -module-name TarwinSched -emit-ir "$src"/*.swift -o "$out/cpu.ll"
    "$clang" -target "$arch" -Os -fstack-usage -c "$out/cpu.ll" -o "$out/cpu.o"
    awk -F '\t' -v arch="$arch" '
        $1 ~ /BootstrapCPUV(6select|12nextSliceEnd|7running|4find|3key|6create|6remove|4wake)/ {
            limit = $1 ~ /6select/ ? 512 : 128
            if ($2 !~ /^[0-9]+$/ || $2 > limit || $3 != "static") {
                print arch ": exceeds " limit " byte static frame budget: " $0 > "/dev/stderr"
                failed = 1
            }
            if ($1 !~ /\.cold\.[0-9]+$/) {
                if ($1 ~ /6select/ && !select++) print arch ": select: " $2 " bytes"
                if ($1 ~ /12nextSliceEnd/ && !slice++) print arch ": nextSliceEnd: " $2 " bytes"
            }
        }
        END { if (!select || !slice) print "missing scheduler frame reports" > "/dev/stderr"
              exit failed || !select || !slice }
    ' "$out/cpu.su"
done
