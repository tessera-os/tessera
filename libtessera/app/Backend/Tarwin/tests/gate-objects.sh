#!/bin/sh
# Cross-link and inspect the real user-side gate without executing a syscall
# on the host OS. A matching signed LibTessera and EL0 test are separate gates.
set -eu
native=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
abi="$native/../../../../tarwin/tarwin-syscall/Sources/TarwinABI"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
bin=$(dirname "${EMBEDDED_SWIFTC:?set to a Swift.org Embedded compiler}")
"${HOST_SWIFTC:-swiftc}" "$native/variants/GateVariants.swift" -o "$out/generator"
for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
    arch=${target%%-*}
    "$out/generator" "$arch" > "$out/gate.ll"
    "$bin/clang" -target "$target" -O2 -Wno-override-module -c "$out/gate.ll" -o "$out/gate.o"
    set -- -target "$target" -wmo -O -parse-as-library -enable-experimental-feature Embedded -no-allocations
    "$EMBEDDED_SWIFTC" "$@" -emit-module -module-name TarwinABI -emit-module-path "$out/TarwinABI.swiftmodule" "$abi"/*.swift
    "$EMBEDDED_SWIFTC" "$@" -module-name LibTesseraTarwin -enable-experimental-feature Extern -D TARWIN_NATIVE_IMAGE \
        -I "$out" -emit-object -o "$out/native.o" "$native"/CallNumbers.swift "$native"/Native*.swift
    "$bin/ld.lld" -r "$out/native.o" "$out/gate.o" -o "$out/linked.o"
    "$bin/llvm-nm" -u "$out/native.o" | grep -Eq ' U libtessera_tarwin_enter$'
    "$bin/llvm-nm" "$out/linked.o" | grep -Eq ' T libtessera_tarwin_enter$'
    case "$arch" in
        aarch64) instruction='svc[[:space:]]+#0' ;;
        x86_64) instruction='syscall' ;;
        riscv64) instruction='ecall' ;;
    esac
    test "$("$bin/llvm-objdump" -d "$out/gate.o" | grep -Ec "[[:space:]]$instruction$")" = 1
    echo "Compiled and linked native gate: $target (not executed)"
done
