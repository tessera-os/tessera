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
set -- "$@" -target "$target" -wmo -Osize -parse-as-library -enable-experimental-feature Embedded -Xfrontend -disable-stack-protector -Xfrontend -function-sections -Xllvm -vectorize-loops=false -Xllvm -vectorize-slp=false -I "$dir"
for src in "$t"/kcore/Sources/KCore "$t"/tarwin-time/Sources/TarwinTime "$t"/tarwin-sched/Sources/TarwinSched "$t"/tarwin-mm/Sources/TarwinMM "$t"/tarwin-boot/Sources/TarwinBoot "$t/../tessera/build/tarwin/Sources/TarwinBootstrap"; do
  module=${src##*/}
  "$tc/swiftc" "$@" -no-allocations -module-name "$module" -emit-module -emit-module-path "$dir/$module.swiftmodule" "$src/"*.swift
done
profile=${GUEST_PROFILE:-kernel}
"$tc/swift" "$here/GuestEntry.swift" "$arch" "$profile" > "$dir/start.s"
"$tc/clang" -target "$target" -march="$march" -c "$dir/start.s" -o "$dir/entry.o"
if [ "$profile" = metal ]; then
  driver=${TVGPU_PACKAGE:-"$t/drivers/tvgpu"}/Sources/TvGpuGuest/MetalPresentation.swift
  set -- "$@" -D METAL_GUEST "$driver" "$here/MetalGuest.swift"
fi
if [ "$profile" = storage ]; then
  vol="$t/trfs/Sources/TRFS"; ipc="$t/tarwin-ipc/Sources/TarwinIPC"
  verify="$t/tarwin-loader/w0/Sources/TarwinW0Verify"
  emit() {
    module=$1; shift
    "$tc/swiftc" "$@" -module-name "$module" -emit-module -emit-module-path "$dir/$module.swiftmodule"
  }
  emit EarlyVolume "$@" "$vol/SnapshotVolume.swift" "$vol/ScopedLookup.swift"
  emit TarwinIPC "$@" "$ipc/Ring.swift" "$ipc/RingEndpoint.swift"
  emit TarwinBlockWire "$@" "$t/tarwin-block/Sources/TarwinBlockWire/Records.swift"
  set -- "$@" -D STORAGE_GUEST "$t/trfs/tests/GuestIO/Storage.swift" "$verify/SHA512.swift" "$verify/MeasurementDigest.swift"
  xcrun --sdk macosx swiftc -framework CryptoKit "$t/trfs/tests/fixtures/make-system-image.swift" -o "$dir/make-image"
  "$dir/make-image" "$dir"
  mv "$dir/system.trfs" "$dir/storage.img"
  [ "$(wc -c < "$dir/storage.img" | tr -d ' ')" = 1048576 ]
  if [ "${STORAGE_FAULT:-none}" = payload ]; then
    # Corrupt byte 77 of the expected file, not the pinned head or metadata.
    printf '\377' | dd of="$dir/storage.img" bs=1 seek=16461 conv=notrunc 2>/dev/null
  fi
fi
"$tc/swiftc" "$@" -no-allocations -module-name TarwinDebugGuest -c "$here/Kernel.swift" "$t/tarboot/tests/FirmwareProbe/Memory.swift" -o "$dir/kernel.o"
"$tc/ld.lld" -T "$here/kernel.ld" --gc-sections -o "$dir/kernel.elf" "$dir/entry.o" "$dir/kernel.o"
"$tc/llvm-objcopy" -O binary "$dir/kernel.elf" "$dir/kernel.bin"
if [ -n "${GUEST_ELF_DIR:-}" ]; then mkdir -p "$GUEST_ELF_DIR"; cp "$dir/kernel.elf" "$GUEST_ELF_DIR/$arch.elf"; fi
"$tc/swift" "$here/Pack.swift" "$arch" "$dir/kernel.bin" "$profile"
