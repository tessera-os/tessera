#!/bin/sh
# Read-only Xperia XZ2 bring-up preflight. This script NEVER flashes, unlocks,
# reboots, installs, formats, or writes to a phone or its partitions.
set -eu

adb=${ADB:-/opt/homebrew/bin/adb}
fastboot=${FASTBOOT:-/opt/homebrew/bin/fastboot}
bundle=${TESSERA_AKARI_BUNDLE:-"$HOME/.tessera-build/out/Tessera-XZ2-akari-UFS-GPU-nodiscard-experimental-20261107.zip"}

for tool in "$adb" "$fastboot"; do
    if [ ! -x "$tool" ]; then
        echo "Missing executable: $tool" >&2
        exit 1
    fi
done

if [ ! -f "$bundle" ] || [ ! -f "$bundle.sha256" ]; then
    echo "Missing experimental bundle or checksum: $bundle" >&2
    exit 1
fi
echo "== Tessera experimental bundle integrity =="
(cd "$(dirname "$bundle")" && shasum -a 256 -c "$(basename "$bundle").sha256")
echo "WARNING: Valid checksum does NOT mean this build is safe to flash."

echo "== Detecting phone (read-only) =="
adb_list=$("$adb" devices)
fastboot_list=$("$fastboot" devices)
adb_count=$(printf '%s\n' "$adb_list" | awk 'NR>1 && $2 == "device" { n++ } END { print n+0 }')
fastboot_count=$(printf '%s\n' "$fastboot_list" | awk '$2 == "fastboot" { n++ } END { print n+0 }')

if [ "$adb_count" -gt 1 ] || [ "$fastboot_count" -gt 1 ]; then
    echo "Multiple devices connected. Refusing to guess which is the Xperia." >&2
    exit 2
fi
if [ "$adb_count" -eq 0 ] && [ "$fastboot_count" -eq 0 ]; then
    if printf '%s\n' "$adb_list" | grep -Eq '(unauthorized|offline)'; then
        echo "ADB lists a device that is not authorized or not ready. Check the phone screen."
    else
        echo "No authorized ADB device or fastboot device detected."
    fi
    exit 2
fi

if [ "$adb_count" -eq 1 ]; then
    serial=$(printf '%s\n' "$adb_list" | awk 'NR>1 && $2 == "device" { print $1 }')
    echo "Authorized ADB device detected; checking Android/recovery properties:"
    for property in ro.product.device ro.product.model ro.boot.flash.locked ro.boot.verifiedbootstate ro.boot.slot_suffix ro.boot.bootloader; do
        value=$("$adb" -s "$serial" shell getprop "$property" 2>/dev/null | tr -d '\r' || true)
        echo "  $property=${value:-<unavailable>}"
    done
fi

if [ "$fastboot_count" -eq 1 ]; then
    serial=$(printf '%s\n' "$fastboot_list" | awk '$2 == "fastboot" { print $1 }')
    echo "Fastboot device detected; reading partition metadata only:"
    for field in product unlocked secure current-slot partition-size:boot partition-size:boot_a partition-size:boot_b partition-size:dtbo; do
        echo "  $field:"
        "$fastboot" -s "$serial" getvar "$field" 2>&1 | sed -n '1,3p' || true
    done
fi

echo "STOP: no installation or flashing was attempted."
echo "Tessera's experimental ZIP is not an ADB-sideloadable OTA or a validated flash image."