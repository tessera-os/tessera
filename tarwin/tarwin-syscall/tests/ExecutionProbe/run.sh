#!/bin/bash
# Disposable firmware diagnostic only; no kernel entry or signed image.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
r=$(cd "$here/../../.." && pwd)
bin=$(dirname "${EMBEDDED_SWIFTC:?set EMBEDDED_SWIFTC to the swift.org toolchain swiftc}")
fw=${QEMU_FIRMWARE:?set QEMU_FIRMWARE to the EDK II firmware directory}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc "$here/RunGuest.swift" -o "$out/guest"
if [[ $# == 0 ]]; then set -- aarch64 x86_64 riscv64; fi
for arch in "$@"; do
    case $arch in
        aarch64) triple=aarch64-none-none-elf; suffix=AA64; vars=arm; code=aarch64;;
        x86_64) triple=x86_64-unknown-none-elf; suffix=X64; vars=i386; code=x86_64;;
        riscv64) triple=riscv64-none-none-eabi; suffix=RISCV64; vars=riscv; code=riscv;;
        *) exit 2;;
    esac
    d="$out/$arch"
    mkdir -p "$d/esp/EFI/BOOT"
    app="$d/esp/EFI/BOOT/BOOT$suffix.EFI"
    flags=(-target "$triple" -enable-experimental-feature Embedded -no-allocations -wmo -O
           -Xfrontend -disable-stack-protector -parse-as-library -I "$d")
    if [[ $arch == x86_64 ]]; then flags+=(-D TARBOOT_EFI_PE_COFF); fi
    module() {
        local mod=$1
        shift
        "$bin/swiftc" "${flags[@]}" -module-name "$mod" -emit-module -emit-module-path "$d/$mod.swiftmodule" "$@"
    }
    for src in "$r"/kcore/Sources/KCore "$r"/{tarwin-boot,tarboot,tarwin-object,tarwin-syscall,tarwin-sync,tarwin-sched,tarwin-ipc}/Sources/Tar* "$r"/tarwin-syscall/providers/Sources/TarwinObjectCalls; do
        module "$(basename "$src")" "$src"/*.swift
    done
    if [[ $arch == aarch64 ]]; then
        module TarwinArchAarch64 "$r/tarwin-arch-aarch64/Sources/TarwinArchAarch64"/*.swift
        module TarwinArmBootstrap "$r/tarwin-syscall/first-entry/Sources/TarwinArmBootstrap"/*.swift
    fi
    native="$r/../libtessera/app/Backend/Tarwin"
    module LibTesseraTarwin "$native"/CallNumbers.swift "$native"/Native*.swift
    "$bin/swiftc" "${flags[@]}" -module-name ExecutionProbe -emit-ir -o "$d/main.ll" "$here/Probe.swift" "$r/tarboot/tests/FirmwareProbe/Memory.swift"
    if [[ $arch == riscv64 ]]; then
        edk=${EDK_BASETOOLS:?set EDK_BASETOOLS to edk2-stable202408 BaseTools}
        "$bin/clang" -target "$triple" -mcmodel=medany -msmall-data-limit=0 -mno-relax -flto -O2 -c "$d/main.ll" -o "$d/main.o"
        "$bin/ld.lld" -m elf64lriscv -pie --no-dynamic-linker --emit-relocs --no-relax --gc-sections -e efi_main -T "$edk/Scripts/GccBase.lds" --defsym=PECOFF_HEADER_SIZE=0x240 "$d/main.o" -o "$d/main.elf"
        "$edk/Source/C/bin/GenFw" -e UEFI_APPLICATION -o "$app" "$d/main.elf"
    else
        "$bin/clang" -target "$arch-unknown-windows-msvc" -mno-stack-arg-probe -flto -Wno-override-module -O2 -c "$d/main.ll" -o "$d/main.obj"
        "$bin/lld-link" /subsystem:efi_application /entry:efi_main /nodefaultlib /opt:ref "/out:$app" "$d/main.obj"
    fi
    cp "$fw/edk2-$vars-vars.fd" "$d/vars.fd"
    "$out/guest" "$arch" "$d" "$fw/edk2-$code-code.fd"
done
