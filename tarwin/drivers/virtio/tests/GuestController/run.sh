#!/bin/bash
# Debug probe of a QEMU-emulated virtio-blk controller after ExitBootServices,
# driven by the VirtioGuest sources. Read-only drive; no kernel entry, signed
# image or DMA isolation claim (identity-mapped loader pages, no vIOMMU).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
r=$(cd "$here/../../../.." && pwd)
bin=$(dirname "${EMBEDDED_SWIFTC:?set EMBEDDED_SWIFTC to the swift.org toolchain swiftc}")
fw=${QEMU_FIRMWARE:?set QEMU_FIRMWARE to the EDK II firmware directory}
out=${GUEST_CONTROLLER_OUT:-$(mktemp -d)}
mkdir -p "$out"
[[ -n ${GUEST_CONTROLLER_OUT:-} ]] || trap 'rm -rf "$out"' EXIT
swiftc "$here/RunGuest.swift" -o "$out/guest"
swiftc "$here/Access.swift" -o "$out/access"
rm -f "$out/system.trfs" "$out/system.trfs.root"
swiftc "$r/trfs/tests/fixtures/make-system-image.swift" -o "$out/fixture"
"$out/fixture" "$out"
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
    flags=(-target "$triple" -enable-experimental-feature Embedded -wmo -O
           -Xfrontend -disable-stack-protector -parse-as-library -I "$d")
    if [[ $arch == x86_64 ]]; then flags+=(-D TARBOOT_EFI_PE_COFF); fi
    # Swift reference counting needs the A extension; keep the soft-float lp64 ABI.
    if [[ $arch == riscv64 ]]; then flags+=(-Xcc -march=rv64imac -Xcc -mabi=lp64); fi
    module() {
        local mod=$1
        shift
        "$bin/swiftc" "${flags[@]}" -no-allocations -module-name "$mod" -emit-module -emit-module-path "$d/$mod.swiftmodule" "$@"
    }
    for name in kcore/KCore tarwin-boot/TarwinBoot tarboot/Tarboot tarwin-object/TarwinObject tarwin-syscall/TarwinABI tarwin-syscall/TarwinSyscall; do
        module "${name#*/}" "$r/${name%/*}/Sources/${name#*/}"/*.swift
    done
    # The TRFS GuestIO reader's modules, built as trfs/tests/GuestIO/check.sh does.
    reader() {
        local mod=$1
        shift
        "$bin/swiftc" "${flags[@]}" -module-name "$mod" -emit-module -emit-module-path "$d/$mod.swiftmodule" "$@"
    }
    reader EarlyVolume "$r/trfs/Sources/TRFS"/{SnapshotVolume,ScopedLookup}.swift
    reader TarwinIPC "$r/tarwin-ipc/Sources/TarwinIPC"/{Ring,RingEndpoint}.swift
    reader TarwinBlockWire "$r/tarwin-block/Sources/TarwinBlockWire/Records.swift"
    module TarwinDevice "$r/tarwin-device/Sources/TarwinDevice"/{PciWalk,Pci,Range,Mcfg,Native,Slot,ConfigCalls}.swift
    # The driver allocates its queue bookkeeping; Heap.swift backs it with loader
    # pages. The probe shares the package to reach the snapshot-limited submitBlock.
    "$bin/swiftc" "${flags[@]}" -module-name VirtioGuest -package-name VirtioGuest -emit-module -emit-module-path "$d/VirtioGuest.swiftmodule" \
        "$r/drivers/virtio/Sources/VirtioGuest"/{Pci,Mmio,SplitRing,Block,BlockConfiguration,BlockRange}.swift
    "$bin/swiftc" "${flags[@]}" -enable-experimental-feature Extern -module-name GuestController -package-name VirtioGuest -emit-ir -o "$d/main.ll" \
        "$here"/{Probe,Sha256,Heap}.swift "$r/tarboot/tests/FirmwareProbe/Memory.swift" \
        "$r/trfs/tests/GuestIO/Storage.swift" "$r/tarwin-loader/w0/Sources/TarwinW0Verify"/{SHA512,MeasurementDigest}.swift
    "$out/access" "$arch" > "$d/access.ll"
    if [[ $arch == riscv64 ]]; then
        edk=${EDK_BASETOOLS:?set EDK_BASETOOLS to edk2-stable202408 BaseTools}
        for f in main access; do
            "$bin/clang" -target "$triple" -march=rv64imac -mabi=lp64 -mcmodel=medany -msmall-data-limit=0 -mno-relax -flto -O2 -Wno-override-module -c "$d/$f.ll" -o "$d/$f.o"
        done
        "$bin/ld.lld" -mllvm -mattr=+m,+a,+c -m elf64lriscv -pie --no-dynamic-linker --emit-relocs --no-relax --gc-sections -e efi_main -T "$edk/Scripts/GccBase.lds" --defsym=PECOFF_HEADER_SIZE=0x240 "$d/main.o" "$d/access.o" -o "$d/main.elf"
        "$edk/Source/C/bin/GenFw" -e UEFI_APPLICATION -o "$app" "$d/main.elf"
    else
        for f in main access; do
            "$bin/clang" -target "$arch-unknown-windows-msvc" -mno-stack-arg-probe -flto -Wno-override-module -O2 -c "$d/$f.ll" -o "$d/$f.obj"
        done
        "$bin/lld-link" /subsystem:efi_application /entry:efi_main /nodefaultlib /opt:ref "/out:$app" "$d/main.obj" "$d/access.obj"
    fi
    cp "$fw/edk2-$vars-vars.fd" "$d/vars.fd"
    "$out/guest" "$arch" "$d" "$fw/edk2-$code-code.fd"
done
