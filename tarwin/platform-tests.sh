#!/bin/sh
# This checks Swift machine code, not KLF kernel-profile TIR or a bootable image.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for pkg in kcore tarboot tarwin-boot tarwin-arch-aarch64 tarwin-arch-x64 tarwin-arch-rv64 tarwin-mm tarwin-time; do
    swift test --package-path "$root/$pkg" --scratch-path "$out/host-$pkg"
done
swift test --package-path "$root/../tessera/build/tarwin" --scratch-path "$out/host-bootstrap"

if [ -n "${EMBEDDED_SWIFTC:-}" ]; then
    composition="$root/../tessera/build/tarwin"
    bin=$(CDPATH= cd -- "$(dirname -- "$EMBEDDED_SWIFTC")" && pwd)
    for target in aarch64-none-none-elf x86_64-unknown-none-elf riscv64-none-none-eabi; do
        dest="$out/$target"
        mkdir "$dest"
        # Resolve the W1 dependency graph in regular Embedded mode. Some
        # higher-level device registries allocate; the checked roots below cannot.
        set -- --package-path "$composition" --scratch-path "$dest/build" \
            --triple "$target" --toolchain "$bin/.." -c release
        "$bin/swift" build "$@" --target TarwinW1Bootstrap -Xswiftc -wmo \
            -Xswiftc -enable-experimental-feature -Xswiftc Embedded \
            -Xswiftc -enable-experimental-feature -Xswiftc Extern \
            -Xswiftc -enable-experimental-feature -Xswiftc Volatile
        modules=$("$bin/swift" build "$@" --show-bin-path)/Modules
        for src in "$root/kcore/Sources/KCore" "$root/tarwin-boot/Sources/TarwinBoot" \
            "$root/tarboot/Sources/Tarboot" "$root/tarwin-arch-aarch64/Sources/TarwinArchAarch64" \
            "$root/tarwin-arch-x64/Sources/TarwinArchX64" "$root/tarwin-arch-rv64/Sources/TarwinArchRv64" \
            "$root/tarwin-mm/Sources/TarwinMM" "$root/tarwin-time/Sources/TarwinTime" \
            "$root/tarwin-sched/Sources/TarwinSched" "$root/tarwin-loader/Sources/TarwinLoader" \
            "$composition"/Sources/*; do
            module=$(basename "$src")
            "$bin/swiftc" -target "$target" -enable-experimental-feature Embedded \
                -enable-experimental-feature Extern -enable-experimental-feature Volatile \
                -no-allocations -wmo -Osize -parse-as-library -module-name "$module" \
                -I "$modules" -emit-object -o "$dest/$module.o" "$src"/*.swift
        done
        echo "$target: built W1 in Embedded mode; separately compiled platform and composition source roots without allocations"
    done
fi
