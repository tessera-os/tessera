#!/bin/bash
# Test images only. See README.md for the required toolchains and firmware.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
bin=$(dirname "${EMBEDDED_SWIFTC:?set EMBEDDED_SWIFTC to the swift.org toolchain swiftc}")
fw=${QEMU_FIRMWARE:?set QEMU_FIRMWARE to the QEMU firmware data directory}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
composition="$root/../tessera/build/tarwin"
swiftc "$composition/Tests/TarbootPreflightTests/Fixture.swift" "$here/WriteFixture.swift" -o "$out/write-fixture"
for isa in "${@:-all}"; do
    if [[ $isa == all ]]; then targets=(aarch64 x86_64 riscv64); else targets=("$isa"); fi
    for arch in "${targets[@]}"; do
        case $arch in
            aarch64) triple=aarch64-none-none-elf; suffix=AA64; vars=arm;;
            x86_64) triple=x86_64-unknown-none-elf; suffix=X64; vars=i386;;
            riscv64) triple=riscv64-none-none-eabi; suffix=RISCV64; vars=riscv;;
            *) echo "unknown firmware target: $arch" >&2; exit 2;;
        esac
        d="$out/$arch"
        mkdir -p "$d/esp/EFI/BOOT"
        image="$d/esp/EFI/BOOT/BOOT$suffix.EFI"
        flags=(-target "$triple" -enable-experimental-feature Embedded -no-allocations -wmo -O
               -Xfrontend -disable-stack-protector -parse-as-library -I "$d")
        if [[ $arch == x86_64 ]]; then flags+=(-D TARBOOT_EFI_PE_COFF); fi
        if [[ ${TARBOOT_TEST_TPM:-0} == 1 ]]; then flags+=(-D TARBOOT_TEST_TPM); fi
        if [[ ${TARBOOT_TEST_DISPLAY:-0} == 1 ]]; then flags+=(-D TARBOOT_TEST_DISPLAY); fi
        if [[ ${TARBOOT_TEST_RNG:-0} == 1 ]]; then flags+=(-D TARBOOT_TEST_RNG); fi
        "$out/write-fixture" "$arch" "$d/esp/BOOT.TIR"
        for src in "$root"/{kcore,tarwin-boot,tarboot,tarwin-mm,tarwin-time,tarwin-sched,tarwin-loader}/Sources/* \
                   "$composition"/Sources/*; do
                mod=$(basename "$src")
                "$bin/swiftc" "${flags[@]}" -module-name "$mod" -emit-module -emit-module-path "$d/$mod.swiftmodule" "$src"/*.swift
        done
        "$bin/swiftc" "${flags[@]}" -module-name Probe -emit-ir -o "$d/probe.ll" "$here/Probe.swift" "$here/Memory.swift" "$here/BootFileProbe.swift" "$here/MeasurementProbe.swift"
        if [[ $arch == riscv64 ]]; then
            edk=${EDK_BASETOOLS:?set EDK_BASETOOLS to built edk2 BaseTools for riscv64}
            "$bin/clang" -target "$triple" -mcmodel=medany -msmall-data-limit=0 -mno-relax -flto -O2 -c "$d/probe.ll" -o "$d/main.o"
            "$bin/ld.lld" -m elf64lriscv -pie --no-dynamic-linker --emit-relocs --no-relax --gc-sections -e efi_main \
                -T "$edk/Scripts/GccBase.lds" --defsym=PECOFF_HEADER_SIZE=0x240 "$d/main.o" -o "$d/probe.elf"
            "$edk/Source/C/bin/GenFw" -e UEFI_APPLICATION -o "$image" "$d/probe.elf"
            code=riscv
        else
            # Use the PE target ABI for all foreign calls; the Swift frontend uses a
            # bare-metal triple because this distribution has no embedded UEFI stdlib.
            "$bin/clang" -target "$arch-unknown-windows-msvc" -mno-stack-arg-probe -flto -Wno-override-module -O2 -c "$d/probe.ll" -o "$d/main.obj"
            "$bin/lld-link" /subsystem:efi_application /entry:efi_main /nodefaultlib /opt:ref "/out:$image" "$d/main.obj"
            code=$arch
        fi
        cp "$fw/edk2-$vars-vars.fd" "$d/vars.fd"
        swift "$here/RunFirmware.swift" "$arch" "$d" "$fw/edk2-$code-code.fd"
    done
done
