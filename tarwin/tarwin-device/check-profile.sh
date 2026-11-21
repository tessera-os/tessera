#!/bin/sh
# Compile one package only. The aggregate acceptance runner lives in conformance.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
package=${1:-$here}
compiler=${SWIFTC:-swiftc}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
  if [ "$(basename "$package")" = tarwin-device ]; then
    for dep in tarwin-object:TarwinObject tarwin-syscall:TarwinSyscall; do
      name=${dep#*:}
      "$compiler" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-module \
        -module-name "$name" "$here/../${dep%:*}/Sources/$name"/*.swift -emit-module-path "$out/$name.swiftmodule"
    done
  fi
  "$compiler" -I "$out" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
    -module-name TarwinIO "$package"/Sources/*/*.swift -o "$out/$target.o"
  if [ "$(basename "$package")" = tarwin-device ]; then
    src="$package/Sources/TarwinDevice"
    "$compiler" -I "$out" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
      -no-allocations -module-name TarwinCritical "$src/Interrupt.swift" "$src/Range.swift" "$src/Dma.swift" \
      "$src/Binding.swift" "$src/Domain.swift" "$src/Slot.swift" "$src/Pci.swift" "$src/Native.swift" -o "$out/$target-critical.o"
  elif [ "$(basename "$package")" = tarwin-gpu ]; then
    "$compiler" -I "$out" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
      -no-allocations -module-name TarwinFence "$package/Sources/TarwinGPU/Timeline.swift" -o "$out/$target-fence.o"
  fi
done
