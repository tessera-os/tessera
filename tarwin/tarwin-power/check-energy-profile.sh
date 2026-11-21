#!/bin/sh
set -eu
src="$(dirname "$0")/Sources/TarwinPower"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
  "${SWIFTC:-swiftc}" -target "$target" -O -wmo -enable-experimental-feature Embedded \
    -no-allocations -parse-as-library -emit-object -module-name TarwinEnergy \
    "$src/Accounting.swift" "$src/EnergyLedger.swift" -o "$out/$target.o"
  printf '%s\n' "$target: no-allocations energy object built"
done
