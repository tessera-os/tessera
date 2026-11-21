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
        extra=()
        if [[ ${TARBOOT_TEST_CPU:-0} != 0 ]]; then
            flags+=(-D TARBOOT_TEST_CPU -enable-experimental-feature Extern)
            if [[ ${TARBOOT_TEST_CPU:-0} == refusal ]]; then
                [[ $arch == aarch64 ]] || exit 2
                flags+=(-D TARBOOT_TEST_CPU_REFUSAL)
            fi
            swift "$composition-stage0/ProcessorVariants.swift" "$arch" > "$d/processor.ll"
            if [[ $arch == riscv64 ]]; then machine="$triple"; else machine="$arch-unknown-windows-msvc"; fi
            "$bin/clang" -target "$machine" -O2 -Wno-override-module -c "$d/processor.ll" -o "$d/processor.o"
            extra+=("$d/processor.o")
        fi
        if [[ -n ${TARBOOT_TEST_STAGE0_ARCHIVE:-} ]]; then
            [[ $arch == aarch64 || ($arch == x86_64 && ${TARBOOT_TEST_CPU:-0} == x64-refusal && -n ${TARBOOT_TEST_SIGNATURE:-}) ]] || exit 2
            flags+=(-D TARBOOT_TEST_STAGE0)
        fi
        modules=()
        entry_source=()
        if [[ ${TARBOOT_TEST_PSCI:-0} == 1 ]]; then
            [[ $arch == aarch64 && ${TARBOOT_TEST_CPU:-0} == 1 && ${TARBOOT_TEST_SMP_TABLES:-0} == 1 ]] || exit 2
            flags+=(-D TARBOOT_TEST_PSCI)
            swift "$composition-stage0/ArmAffinityProbe.swift" > "$d/affinity.ll"
            "$bin/clang" -target aarch64-unknown-windows-msvc -Wno-override-module -c "$d/affinity.ll" -o "$d/affinity.obj"
            extra+=("$d/affinity.obj")
        fi
        if [[ ${TARBOOT_TEST_TRANSLATION:-0} == 1 ]]; then
            [[ $arch == aarch64 && ${TARBOOT_TEST_CPU:-0} == 1 && ${TARBOOT_TEST_SMP_TABLES:-0} == 0 && -z ${TARBOOT_TEST_SIGNATURE:-} ]] || exit 2
            flags+=(-D TARBOOT_TEST_TRANSLATION)
            entry_source+=("$here/TranslationProbe.swift")
            swift "$composition-stage0/ArmTranslationProbe.swift" > "$d/translation.ll"
            "$bin/clang" -target aarch64-unknown-windows-msvc -Wno-override-module -c "$d/translation.ll" -o "$d/translation.obj"
            extra+=("$d/translation.obj")
        fi
        if [[ ${TARBOOT_ENTER_W0:-0} == 1 ]]; then
            [[ $arch == aarch64 && -n ${TARBOOT_TEST_SIGNATURE:-} && ${TARBOOT_TEST_RNG:-0} == 1 && ${TARBOOT_TEST_DISPLAY:-0} == 1 && ${TARBOOT_TEST_SMP_TABLES:-0} == 0 && ${TARBOOT_BAD_SIGNATURE:-0} == 0 ]] || exit 2
            flags+=(-D TARBOOT_ENTER_W0)
            entry_source+=("$composition-stage0/QEMUEntry.swift")
            swift "$composition-stage0/ArmHandoffVariants.swift" > "$d/entry.ll"
            "$bin/clang" -target aarch64-unknown-windows-msvc -Wno-override-module -c "$d/entry.ll" -o "$d/entry.obj"
            extra+=("$d/entry.obj")
        fi
        if [[ -n ${TARBOOT_TEST_SIGNATURE:-} ]]; then
            if [[ $arch == x86_64 && ${TARBOOT_TEST_CPU:-0} == x64-refusal ]]; then
                [[ ${TARBOOT_BAD_SIGNATURE:-0} == 0 ]] || exit 2
                flags+=(-D TARBOOT_TEST_X64_REFUSAL)
            else
                [[ $arch == aarch64 && ${TARBOOT_TEST_CPU:-0} == 1 ]] || exit 2
            fi
            [[ ${TARBOOT_TEST_FLOOR:-0} == 1 && -n ${TARBOOT_TEST_STAGE0_ARCHIVE:-} && -f ${TARBOOT_QEMU_ENROLLMENT:-} ]] || exit 2
            flags+=(-D TARBOOT_TEST_SIGNED)
            modules+=("$root/tarwin-loader/w0/Sources/TarwinW0Verify")
            cp "$TARBOOT_TEST_SIGNATURE" "$d/esp/BOOT.SIG"
            if [[ ${TARBOOT_BAD_SIGNATURE:-0} == 1 ]]; then
                flags+=(-D TARBOOT_BAD_SIGNATURE)
                swift -e 'import Foundation; let u=URL(fileURLWithPath:CommandLine.arguments[1]); var b=try Data(contentsOf:u); guard !b.isEmpty else { exit(2) }; b[b.count-1] ^= 1; try b.write(to:u)' "$d/esp/BOOT.SIG"
            fi
        fi
        if [[ ${TARBOOT_TEST_TPM:-0} == 1 ]]; then flags+=(-D TARBOOT_TEST_TPM); fi
        if [[ ${TARBOOT_TEST_FLOOR:-0} == 1 ]]; then
            [[ ${TARBOOT_TEST_TPM:-0} == 1 ]] || { echo 'floor requires disposable TPM' >&2; exit 2; }
            flags+=(-D TARBOOT_TEST_FLOOR)
        fi
        if [[ ${TARBOOT_TEST_SECURE_FIRMWARE:-0} == 1 ]]; then
            [[ $arch == x86_64 ]] || { echo 'secure firmware fixture requires x86_64' >&2; exit 2; }
            flags+=(-D TARBOOT_TEST_SECURE_FIRMWARE)
        fi
        if [[ ${TARBOOT_TEST_DISPLAY:-0} == 1 ]]; then flags+=(-D TARBOOT_TEST_DISPLAY); fi
        if [[ ${TARBOOT_TEST_RNG:-0} == 1 ]]; then flags+=(-D TARBOOT_TEST_RNG); fi
        if [[ ${TARBOOT_TEST_SMP_TABLES:-0} == 1 ]]; then flags+=(-D TARBOOT_TEST_SMP_TABLES); fi
        "$out/write-fixture" "$arch" "$d/esp/BOOT.TIR" "$d/FixtureHashes.swift"
        for src in "$root"/{kcore/Sources/KCore,tarwin-boot/Sources/TarwinBoot,tarboot/Sources/Tarboot,tarwin-mm/Sources/TarwinMM,tarwin-time/Sources/TarwinTime,tarwin-sched/Sources/TarwinSched,tarwin-loader/Sources/TarwinLoader} \
                   "$root"/tarwin-arch-{aarch64/Sources/TarwinArchAarch64,x64/Sources/TarwinArchX64} "$composition"/Sources/{TarbootPreflight,TarwinBootstrap} ${modules[@]+"${modules[@]}"}; do
                mod=$(basename "$src")
                "$bin/swiftc" "${flags[@]}" -module-name "$mod" -emit-module -emit-module-path "$d/$mod.swiftmodule" "$src"/*.swift
        done
        "$bin/swiftc" "${flags[@]}" -module-name Probe -emit-ir -o "$d/probe.ll" "$here/Probe.swift" "$here/Memory.swift" "$here/BootFileProbe.swift" "$here/MeasurementProbe.swift" "$here/ProcessorProbe.swift" "$here/SignedArchive.swift" "$d/FixtureHashes.swift" ${entry_source[@]+"${entry_source[@]}"}
        if [[ $arch == riscv64 ]]; then
            edk=${EDK_BASETOOLS:?set EDK_BASETOOLS to built edk2 BaseTools for riscv64}
            "$bin/clang" -target "$triple" -mcmodel=medany -msmall-data-limit=0 -mno-relax -flto -O2 -c "$d/probe.ll" -o "$d/main.o"
            "$bin/ld.lld" -m elf64lriscv -pie --no-dynamic-linker --emit-relocs --no-relax --gc-sections -e efi_main \
                -T "$edk/Scripts/GccBase.lds" --defsym=PECOFF_HEADER_SIZE=0x240 "$d/main.o" ${extra[@]+"${extra[@]}"} -o "$d/probe.elf"
            "$edk/Source/C/bin/GenFw" -e UEFI_APPLICATION -o "$image" "$d/probe.elf"
            code=riscv
        else
            # Use the PE target ABI for all foreign calls; the Swift frontend uses a
            # bare-metal triple because this distribution has no embedded UEFI stdlib.
            "$bin/clang" -target "$arch-unknown-windows-msvc" -mno-stack-arg-probe -flto -Wno-override-module -O2 -c "$d/probe.ll" -o "$d/main.obj"
            "$bin/lld-link" /subsystem:efi_application /entry:efi_main /nodefaultlib /opt:ref "/out:$image" "$d/main.obj" ${extra[@]+"${extra[@]}"}
            code=$arch
        fi
        if [[ ${TARBOOT_TEST_SECURE_FIRMWARE:-0} == 1 ]]; then
            # Only disposable guest NVRAM and test keys in the private scratch
            # directory. Never read the host keychain, enroll keys on the host,
            # or install private keys on the guest ESP.
            umask 077
            code=x86_64-secure
            for key in pk kek db; do
                openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj "/CN=Tarwin disposable $key/" \
                    -keyout "$d/$key.key" -out "$d/$key.crt" >/dev/null 2>&1
            done
            owner=$(uuidgen)
            virt-fw-vars --input "$fw/edk2-$vars-vars.fd" --output "$d/enrolled.fd" --secure-boot \
                --set-pk "$owner" "$d/pk.crt" --add-kek "$owner" "$d/kek.crt" --add-db "$owner" "$d/db.crt"
            cp "$d/enrolled.fd" "$d/vars.fd"
            swift "$here/RunFirmware.swift" "$arch" "$d" "$fw/edk2-$code-code.fd" unsigned-control
            cp "$d/enrolled.fd" "$d/vars.fd"
            osslsigncode sign -h sha256 -certs "$d/db.crt" -key "$d/db.key" -in "$image" -out "$d/signed.efi"
            mv "$d/signed.efi" "$image"
        else
            cp "$fw/edk2-$vars-vars.fd" "$d/vars.fd"
        fi
        if [[ ${TARBOOT_ENTER_W0:-0} == 1 ]] && LC_ALL=C grep -aFq 'TARWIN W0 PASS' "$image"; then
            echo "kernel-only pass marker found in EFI image" >&2; exit 1
        fi
        swift "$here/RunFirmware.swift" "$arch" "$d" "$fw/edk2-$code-code.fd"
    done
done
