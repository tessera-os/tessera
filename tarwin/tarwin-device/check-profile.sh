#!/bin/sh
# Compile one package only. The aggregate acceptance runner lives in conformance.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
package=${1:-$here}
compiler=${SWIFTC:-swiftc}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
  "$compiler" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
    -module-name TarwinIO "$package"/Sources/*/*.swift -o "$out/$target.o"
  if [ "$(basename "$package")" = tarwin-device ]; then
    src="$package/Sources/TarwinDevice"
    "$compiler" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
      -no-allocations -module-name TarwinCritical "$src/Interrupt.swift" "$src/Range.swift" "$src/Dma.swift" \
      "$src/Slot.swift" "$src/Pci.swift" "$src/Native.swift" -o "$out/$target-critical.o"
  fi
done
