#!/bin/sh
# Instantiate the measured mount, not the full nameservice, without a heap.
set -eu
d=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
t=$(CDPATH='' cd -- "$d/../../.." && pwd)
v=$t/tarwin-loader/w0/Sources/TarwinW0Verify
c=${SWIFTC:-swiftc}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
  "$c" -enable-experimental-feature Embedded -O -wmo -target "$target" -parse-as-library \
    -emit-module -module-name EarlyVolume "$t/trfs/Sources/TRFS/SnapshotVolume.swift" \
    "$t/trfs/Sources/TRFS/ScopedLookup.swift" -emit-module-path "$out/EarlyVolume.swiftmodule"
  "$c" -enable-experimental-feature Embedded -O -wmo -target "$target" -parse-as-library \
    -no-allocations -emit-object -module-name EarlyMount -I "$out" "$v/SHA512.swift" \
    "$v/MeasurementDigest.swift" "$d/EarlyRoot.swift" -o "$out/probe.o"
  echo "$target: measured root reader and SHA-256 compiled without allocations"
done
