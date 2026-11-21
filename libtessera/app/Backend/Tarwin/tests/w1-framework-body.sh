#!/bin/sh
# Build the body only. The RIDL veneer, metadata and trust pins come from
# separate train inputs. This does not produce a framework or launch it.
set -eu
test "$#" = 1 && test ! -e "$1" || { echo "expected unused output object path" >&2; exit 2; }
native=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
abi="$native/../../../../tarwin/tarwin-syscall/Sources/TarwinABI"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
bin=$(dirname "${EMBEDDED_SWIFTC:?set to a Swift.org Embedded compiler}")
target=aarch64-none-none-elf
symbol=libtessera_tarwin_process_current_body
"${HOST_SWIFTC:-swiftc}" -parse-as-library "$native/variants/GateVariants.swift" "$native/CallNumbers.swift" -o "$out/generate"
"$out/generate" aarch64 --w1-process-current > "$out/gate.ll"
compile() {
    "$EMBEDDED_SWIFTC" -target "$target" -wmo -O -parse-as-library -no-allocations -enable-experimental-feature Embedded "$@"
}
compile -module-name TarwinABI -emit-module -emit-module-path "$out/TarwinABI.swiftmodule" "$abi"/*.swift
compile -module-name LibTesseraTarwin -I "$out" -enable-experimental-feature Extern -D TARWIN_W1_EXPORT \
    -emit-ir "$native/NativeEntry.swift" "$native/NativeProcess.swift" "$native/CallNumbers.swift" -o "$out/body.ll"
for part in body gate; do
    "$bin/clang" -target "$target" -ffunction-sections -flto -O2 -Wno-override-module -c "$out/$part.ll" -o "$out/$part.o"
done
"$bin/ld.lld" -r --gc-sections -u "$symbol" "$out/body.o" "$out/gate.o" -o "$out/final.o"
test -z "$("$bin/llvm-nm" -u "$out/final.o")"
"$bin/llvm-nm" "$out/final.o" | grep -Fq " T $symbol"
"$bin/llvm-objdump" -dr "$out/final.o" > "$out/assembly"
test "$(grep -Ec '[[:space:]]svc[[:space:]]+#0$' "$out/assembly")" = 1
if grep -Eq '[[:space:]](bl|blr)[[:space:]]|[[:space:]]sp([,[:space:]]|$)|\[sp' "$out/assembly"; then
    echo "unexpected call or stack use in W1 body" >&2
    exit 1
fi
cp "$out/final.o" "$1"
