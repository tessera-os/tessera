#!/bin/sh
# This checks Swift machine code, not KLF kernel-profile TIR or a bootable image.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for pkg in kcore tarboot tarwin-boot tarwin-arch-aarch64 tarwin-arch-x64 tarwin-arch-rv64 tarwin-mm tarwin-time; do
    swift test --package-path "$root/$pkg" --scratch-path "$out/host-$pkg"
done

if [ -n "${EMBEDDED_SWIFTC:-}" ]; then
    for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
        dest="$out/$target"
        mkdir "$dest"
        for pkg in kcore tarboot tarwin-boot tarwin-arch-aarch64 tarwin-arch-x64 tarwin-arch-rv64 tarwin-mm tarwin-time; do
            for src in "$root/$pkg"/Sources/*; do
                module=$(basename "$src")
                "$EMBEDDED_SWIFTC" -target "$target" -enable-experimental-feature Embedded \
                    -no-allocations -wmo -Osize -parse-as-library -module-name "$module" \
                    -I "$dest" -emit-module -emit-module-path "$dest/$module.swiftmodule" \
                    -emit-object -o "$dest/$module.o" "$src"/*.swift
            done
        done
        echo "$target: built eight non-allocating Embedded Swift modules"
    done
fi
