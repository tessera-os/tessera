#!/bin/bash
# Intake-only, non-restorable AArch64 QEMU debug kernel. Never W0 or EL0 evidence.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../tarwin" && pwd)
bin=$(dirname "${EMBEDDED_SWIFTC:?set to Embedded Swift compiler}")
out=${1:?usage: w1-intake-object.sh NEW-OUTPUT.o PUBLIC-INSTALL BOOT-SHA256 SYSTEM-SHA256}
[[ $# == 4 && ! -e $out ]] || exit 2
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
triple=aarch64-none-none-elf
flags=(-target "$triple" -enable-experimental-feature Embedded -enable-experimental-feature Extern
       -D TARWIN_NON_RESTORABLE_DEBUG -no-allocations -parse-as-library -wmo -Osize
       -Xfrontend -disable-stack-protector -Xllvm -vectorize-slp=false -Xllvm -vectorize-loops=false
       -Xcc -mgeneral-regs-only -Xcc -mstrict-align -I "$d")
module() {
    local name=$1
    shift
    "$bin/swiftc" "${flags[@]}" -module-name "$name" -emit-module -emit-module-path "$d/$name.swiftmodule" "$@"
}
for path in kcore/Sources/KCore tarwin-boot/Sources/TarwinBoot tarboot/Sources/Tarboot \
            tarwin-loader/Sources/TarwinLoader tarwin-loader/w0/Sources/TarwinW0Verify \
            tarwin-security/random/Sources/TarwinRandomCore tarwin-security/random/Sources/TarwinKernelRandom; do
    module "${path##*/}" "$root/$path"/*.swift
done
module TarwinArchAarch64 "$root/tarwin-arch-aarch64/Sources/TarwinArchAarch64/"*.swift
module TarwinTime "$root/tarwin-time/Sources/TarwinTime/"*.swift
module TarwinDevice "$root"/tarwin-device/Sources/TarwinDevice/{Range,ColdVirtPCI,VirtBootFence}.swift
module TarwinW1Bootstrap "$here"/../tarwin/Sources/TarwinW1Bootstrap/{ColdBus,QEMUReverification,ColdKernelIntake,ColdLog,InitMeasurement,ColdKernelMeasurement,ColdPrivateImages,ColdHostPages,ColdHostImage,ClockPage,ExecutablePages,FramePool,ThreadStorage}.swift
"$bin/swiftc" "${flags[@]}" -module-name W1ColdKernel -emit-ir "$here"/Kernel/{W1Entry,W1Authority}.swift -o "$d/kernel.ll"
"$bin/swiftc" "${flags[@]}" -module-name W1ColdMemory -emit-ir "$here/Kernel/ColdMemory.swift" -o "$d/memory.ll"
swift "$here/W1PublicInstallation.swift" "$2" "$3" "$4" > "$d/install.ll"
swift "$here/ArmFIFOAccess.swift" > "$d/mmio.ll"
swift "$here/ArmHandoffVariants.swift" >> "$d/mmio.ll"
swift "$here/ProcessorVariants.swift" aarch64 > "$d/processor.ll"
for name in kernel install mmio processor memory; do
    "$bin/clang" -target "$triple" -mgeneral-regs-only -mstrict-align -Oz -fPIC -ffunction-sections -fdata-sections \
        -Wno-override-module -c "$d/$name.ll" -o "$d/$name.o"
done
"$bin/ld.lld" -r --gc-sections -u memcpy -u memmove -u memset "$d/memory.o" -o "$d/primitives.o"
if "$bin/llvm-objdump" -r "$d/primitives.o" | grep -E 'R_AARCH64_(CALL|JUMP)26[[:space:]]+mem(cpy|move|set)$'; then
    echo 'cold memory primitive lowered to a recursive library call' >&2; exit 1
fi
"$bin/ld.lld" -r --gc-sections -e tarwin_start_body "$d"/{kernel,install,mmio,processor,primitives}.o -o "$d/live.o"
"$bin/llvm-nm" -u "$d/live.o" > "$d/undefined"
if [[ -s $d/undefined ]]; then
    echo 'unresolved reference in cold kernel' >&2; cat "$d/undefined" >&2; exit 1
fi
if "$bin/llvm-objdump" -h "$d/live.o" | grep -E '\.(bss|data)(\.|[[:space:]])' > "$d/writable"; then
    echo 'mutable static data is not admitted by the cold kernel signer' >&2
    cat "$d/writable" >&2; exit 1
fi
"$bin/llvm-objdump" -d --no-show-raw-insn "$d/live.o" > "$d/assembly"
if grep -Eq '[[:space:],]([vqdsbhz][0-9]+)([.,[:space:]]|$)' "$d/assembly"; then
    echo 'unexpected FP/vector instruction in cold kernel' >&2; exit 1
fi
cp "$d/live.o" "$out"
