#!/bin/sh
# Compile one package only. The aggregate acceptance runner lives in conformance.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
package=${1:-$here}
compiler=${SWIFTC:-swiftc}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
  case "$(basename "$package")" in
    tarwin-device) deps="kcore:KCore tarwin-boot:TarwinBoot tarwin-ipc:TarwinIPC tarwin-device:TarwinIoCompletion tarwin-object:TarwinObject tarwin-syscall:TarwinABI tarwin-syscall:TarwinSyscall" ;;
    tarwin-block) deps="tarwin-ipc:TarwinIPC tarwin-device:TarwinIoCompletion tarwin-block:TarwinBlockWire" ;;
    tarwin-gpu) deps="tarwin-object:TarwinObject tarwin-syscall:TarwinABI tarwin-syscall:TarwinSyscall tarwin-sched:TarwinSched" ;;
    tarwin-net) deps="tarwin-ipc:TarwinIPC tarwin-device:TarwinIoCompletion tarwin-net:TarwinNetWire tarwin-object:TarwinObject tarwin-syscall:TarwinABI tarwin-syscall:TarwinSyscall" ;;
    trfs) deps="kcore:KCore tarwin-mm:TarwinMM tarwin-ipc:TarwinIPC trfs:TarwinFsWire tarwin-object:TarwinObject tarwin-syscall:TarwinABI tarwin-syscall:TarwinSyscall tarwin-device:TarwinIoCompletion" ;;
    *) deps="" ;;
  esac
  for dep in $deps; do
    name=${dep#*:}
    "$compiler" -I "$out" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-module \
      -module-name "$name" "$here/../${dep%:*}/Sources/$name"/*.swift -emit-module-path "$out/$name.swiftmodule"
  done
  if [ "$(basename "$package")" = tarwin-device ]; then
    set -- "$package"/Sources/TarwinDevice/*.swift
  elif [ "$(basename "$package")" = tarwin-block ]; then
    set -- "$package"/Sources/TarwinBlock/*.swift
  elif [ "$(basename "$package")" = tarwin-net ]; then
    set -- "$package"/Sources/TarwinNet/*.swift
  elif [ "$(basename "$package")" = trfs ]; then
    set -- "$package"/Sources/TRFS/*.swift
  else
    set -- "$package"/Sources/*/*.swift
  fi
  "$compiler" -I "$out" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
    -module-name TarwinIO "$@" -o "$out/$target.o"
  if [ "$(basename "$package")" = tarwin-device ]; then
    src="$package/Sources/TarwinDevice"
    "$compiler" -I "$out" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
      -no-allocations -module-name TarwinCritical "$src/Interrupt.swift" "$src/Range.swift" "$src/Dma.swift" \
      "$src/Vtd.swift" "$src/PortInterrupt.swift" "$src/IoRing.swift" "$src/Binding.swift" "$src/Domain.swift" "$src/Slot.swift" "$src/Pci.swift" "$src/Native.swift" -o "$out/$target-critical.o"
  elif [ "$(basename "$package")" = trfs ]; then
    "$compiler" -I "$out" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
      -no-allocations -module-name TrfsSector "$package/Sources/TRFS/Pager.swift" "$package/Sources/TRFS/XtsSector.swift" -o "$out/$target-xts.o"
  elif [ "$(basename "$package")" = tarwin-gpu ]; then
    "$compiler" -I "$out" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
      -no-allocations -module-name TarwinFence "$package/Sources/TarwinGPU/Timeline.swift" "$package/Sources/TarwinGPU/FenceObject.swift" "$package/Sources/TarwinGPU/Presentation.swift" -o "$out/$target-fence.o"
  elif [ "$(basename "$package")" = tarwin-power ]; then
    "$compiler" -target "$target" -enable-experimental-feature Embedded -O -wmo -parse-as-library -emit-object \
      -no-allocations -module-name TarwinWake "$package/Sources/TarwinPower/WakeGate.swift" -o "$out/$target-wake.o"
  fi
done
