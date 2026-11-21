#!/bin/bash
# Produce a live-section-only relocatable input for the stage-0 A12 bridge.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
bin=$(dirname "${EMBEDDED_SWIFTC:?set to swiftc from a macOS Embedded Swift toolchain}")
out=${1:?usage: kernel-object.sh NEW-OUTPUT.o [aarch64|x86_64]}
case ${2:-aarch64} in
    aarch64) triple=aarch64-none-none-elf; entry=tarwin_start; cpu=(-mgeneral-regs-only);;
    x86_64) triple=x86_64-unknown-none-elf; entry=tarwin_start_body; cpu=(-mno-sse -mno-sse2 -mno-mmx -mno-red-zone);;
    *) exit 2;;
esac
[[ ! -e $out ]]
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
flags=(-target "$triple" -enable-experimental-feature Embedded -no-allocations
       -wmo -Osize -Xfrontend -disable-stack-protector -Xllvm -vectorize-slp=false
       -Xllvm -vectorize-loops=false -parse-as-library -I "$d")
for opt in "${cpu[@]}"; do flags+=(-Xcc "$opt"); done
for src in "$root"/tarwin/{kcore,tarwin-boot,tarwin-mm,tarwin-time,tarwin-sched}/Sources/* \
           "$here/../tarwin/Sources/TarwinBootstrap"; do
    module=$(basename "$src")
    "$bin/swiftc" "${flags[@]}" -module-name "$module" -emit-module \
        -emit-module-path "$d/$module.swiftmodule" "$src"/*.swift
done
"$bin/swiftc" "${flags[@]}" -module-name Stage0Kernel -emit-ir "$here/Kernel/Entry.swift" \
    "$root/tarwin/tarboot/tests/FirmwareProbe/Memory.swift" -o "$d/kernel.ll"
if [[ $entry == tarwin_start_body ]]; then
    # IR input already has per-function target attributes. Clang's C frontend
    # red-zone switch alone does not change an existing IR function.
    sed -E '/^attributes #[0-9]+ = \{/ { /noredzone/!s/ = \{/ = { noredzone/; }' "$d/kernel.ll" > "$d/no-red-zone.ll"
    mv "$d/no-red-zone.ll" "$d/kernel.ll"
fi
"$bin/clang" -target "$triple" "${cpu[@]}" -Oz -fPIC -ffunction-sections -fdata-sections \
    -c "$d/kernel.ll" -o "$d/kernel.o"
"$bin/ld.lld" -r --gc-sections -e "$entry" "$d/kernel.o" -o "$d/live.o"
"$bin/llvm-objdump" -d --no-show-raw-insn "$d/live.o" > "$d/assembly"
if grep -Eq '[[:space:],]([vqdsbhz][0-9]+)([.,[:space:]]|$)|%(xmm|ymm|zmm|mm|st|k[0-7])|-[[:xdigit:]x]+\(%rsp\)' "$d/assembly"; then
    echo "floating-point or vector register in stage-0 kernel" >&2
    exit 1
fi
cp "$d/live.o" "$out"
