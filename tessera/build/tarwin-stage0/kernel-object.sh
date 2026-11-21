#!/bin/bash
# Produce a live-section-only relocatable input for the stage-0 A12 bridge.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
bin=$(dirname "${EMBEDDED_SWIFTC:?set to swiftc from a macOS Embedded Swift toolchain}")
out=${1:?usage: kernel-object.sh NEW-OUTPUT.o}
[[ ! -e $out ]]
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
flags=(-target aarch64-none-none-elf -enable-experimental-feature Embedded -no-allocations
       -wmo -Osize -Xfrontend -disable-stack-protector -Xllvm -vectorize-slp=false
       -Xllvm -vectorize-loops=false -Xcc -mgeneral-regs-only -parse-as-library -I "$d")
for src in "$root"/tarwin/{kcore,tarwin-boot,tarwin-mm,tarwin-time,tarwin-sched}/Sources/* \
           "$here/../tarwin/Sources/TarwinBootstrap"; do
    module=$(basename "$src")
    "$bin/swiftc" "${flags[@]}" -module-name "$module" -emit-module \
        -emit-module-path "$d/$module.swiftmodule" "$src"/*.swift
done
"$bin/swiftc" "${flags[@]}" -module-name Stage0Kernel -emit-ir "$here/Kernel/Entry.swift" \
    "$root/tarwin/tarboot/tests/FirmwareProbe/Memory.swift" -o "$d/kernel.ll"
"$bin/clang" -target aarch64-none-none-elf -mgeneral-regs-only -Oz -fPIC -ffunction-sections -fdata-sections \
    -c "$d/kernel.ll" -o "$d/kernel.o"
"$bin/ld.lld" -r --gc-sections -e tarwin_start "$d/kernel.o" -o "$d/live.o"
"$bin/llvm-objdump" -d --no-show-raw-insn "$d/live.o" > "$d/assembly"
if grep -Eq '[[:space:],]([vqdsbhz][0-9]+)([.,[:space:]]|$)' "$d/assembly"; then
    echo "floating-point or vector register in stage-0 kernel" >&2
    exit 1
fi
cp "$d/live.o" "$out"
