#!/bin/bash
# Host protocol regression plus allocation-disabled instantiation for debug guests.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
t=$(cd "$here/../../.." && pwd)
v="$t/tarwin-loader/w0/Sources/TarwinW0Verify"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
c=${HOST_SWIFTC:-swiftc}
volume=("$t"/trfs/Sources/TRFS/{SnapshotVolume,ScopedLookup}.swift)
ipc=("$t"/tarwin-ipc/Sources/TarwinIPC/{Ring,RingEndpoint}.swift)
wire=("$t/tarwin-block/Sources/TarwinBlockWire/Records.swift")
core=("$v"/{SHA512,MeasurementDigest}.swift "$here/Storage.swift")
flags=(-O -wmo -parse-as-library -I "$out")
module() {
  local n=$1
  shift
  "$c" "${flags[@]}" -emit-module -emit-module-path "$out/$n.swiftmodule" -module-name "$n" "$@"
}
module EarlyVolume -emit-object -o "$out/volume.o" "${volume[@]}"
module TarwinIPC -emit-object -o "$out/ipc.o" "${ipc[@]}"
module TarwinBlockWire -emit-object -o "$out/wire.o" "${wire[@]}"
"$c" "${flags[@]}" "${core[@]}" "$here/Check.swift" "$out"/{volume,ipc,wire}.o -o "$out/check"
"$c" "$t/trfs/tests/fixtures/make-system-image.swift" -o "$out/fixture"
"$out/fixture" "$out"
"$out/check" "$out/system.trfs"
cat >"$out/Entry.swift" <<'SWIFT'
@_extern(c, "read_sector") private func readSector(_ grant: UnsafeMutableRawPointer) -> Bool
private struct ProbeTransport: GuestStorageTransport {
  func exchange(_ grant: UnsafeMutableRawBufferPointer) -> Bool { readSector(grant.baseAddress!) }
}
@_cdecl("test_guest_storage") public func run(_ p: UnsafeMutableRawPointer) -> Bool {
  exerciseGuestStorage(.init(start: p, count: 16384), transport: ProbeTransport())
}
SWIFT
for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
  c=${SWIFTC:-swiftc}
  flags=(-target "$target" -enable-experimental-feature Embedded -Osize -wmo -parse-as-library -I "$out")
  module EarlyVolume "${volume[@]}"
  module TarwinIPC "${ipc[@]}"
  module TarwinBlockWire "${wire[@]}"
  "$c" "${flags[@]}" -enable-experimental-feature Extern -no-allocations \
    -emit-object "${core[@]}" "$out/Entry.swift" -o "$out/guest.o"
  "${LLVM_NM:-$(dirname "$(command -v "$c")")/llvm-nm}" -u "$out/guest.o" >"$out/imports"
  if grep -Eq 'swift_(retain|release|allocObject)' "$out/imports"; then
    echo "$target: unexpected runtime dependency" >&2; exit 1
  fi
  echo "$target: compiled authenticated file read without allocation"
done
