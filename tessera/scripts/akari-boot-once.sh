#!/bin/sh
# Xperia XZ2 read-only preflight. Optional --boot-once boots a RAM image
# without flash/erase/format/repartition/bootloader unlock/slot modification.
# DO NOT change this script to automatically flash UFS-enabled boot images.
set -eu

mode=${1:---probe}
case "$mode" in
    --probe|--boot-once) ;;
    *) echo "Usage: sh akari-boot-once.sh [--probe|--boot-once]" >&2; exit 64 ;;
esac

basedir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image="$basedir/boot-test-ufs-disabled.img"
fastboot=${FASTBOOT:-/opt/homebrew/bin/fastboot}
if [ ! -x "$fastboot" ]; then
    echo "fastboot missing at $fastboot" >&2
    exit 1
fi
if [ ! -f "$image" ] || [ ! -f "$basedir/SHA256SUMS" ]; then
    echo "Extract all contents of the Tessera fastboot test ZIP together." >&2
    exit 1
fi
(cd "$basedir" && shasum -a 256 -c SHA256SUMS) || exit 1

devices=$("$fastboot" devices)
count=$(printf '%s\n' "$devices" | awk '$2 == "fastboot" { n++ } END { print n+0 }')
if [ "$count" -ne 1 ]; then
    echo "Expected exactly ONE fastboot-connected Xperia, found $count." >&2
    echo "Power off, hold Volume Up and connect USB (blue LED)." >&2
    exit 2
fi
serial=$(printf '%s\n' "$devices" | awk '$2 == "fastboot" { print $1 }')

# Sony's fastboot replies can be on stdout or stderr, with `(bootloader)`
# prefixes. A missing value causes a hard stop, not a guessed default.
getvar() {
    "$fastboot" -s "$serial" getvar "$1" 2>&1 | awk -v key="$1" '
        index($0, key ":") {
            value = substr($0, index($0, key ":") + length(key) + 1)
            sub(/^[[:space:]]*/, "", value)
            sub(/\r$/, "", value)
            print value
            exit
        }
    '
}
product=$(getvar product)
unlocked=$(getvar unlocked)
slot=$(getvar current-slot)
echo "Fastboot device serial: $serial"
echo "Product: ${product:-unavailable}; unlocked: ${unlocked:-unavailable}; slot: ${slot:-unavailable}"

case "$product" in
    akari|H8216|H8266|H8276|H8296|h8216|h8266|h8276|h8296) ;;
    *) echo "STOP: unexpected product; cannot prove this is a regular Xperia XZ2." >&2; exit 3 ;;
esac
case "$unlocked" in
    yes|true|1) ;;
    *) echo "STOP: bootloader unlock has not been proven. No unlock is attempted." >&2; exit 3 ;;
esac
case "$slot" in
    a|b) ;;
    *) echo "STOP: A/B slot detection failed." >&2; exit 3 ;;
esac

size=$(getvar "partition-size:boot_$slot")
if [ -z "$size" ]; then
    size=$(getvar 'partition-size:boot')
fi
if [ -z "$size" ]; then
    echo "STOP: cannot obtain the phone's actual boot partition size." >&2
    exit 3
fi
if ! capacity=$(python3 - "$size" <<'PY'
import sys
try:
    capacity = int(sys.argv[1], 0)
    if capacity <= 0: raise ValueError
except ValueError: sys.exit(1)
print(capacity)
PY
); then
    echo "STOP: fastboot returned an invalid boot partition size: $size" >&2
    exit 3
fi
bytes=$(wc -c < "$image" | tr -d ' ')
echo "Verified boot partition size: $capacity bytes; candidate: $bytes bytes"
if [ "$bytes" -gt "$capacity" ]; then
    echo "STOP: candidate exceeds device partition capacity." >&2
    exit 3
fi

echo "Safe boot-test DTB: UFS host/PHY are DISABLED (no UFS storage access)."
echo "No Sony DTBO, AVB or boot compatibility is yet verified on hardware."
if [ "$mode" = "--probe" ]; then
    echo "READ-ONLY PREFLIGHT PASSED; NO DEVICE CHANGES MADE."
    exit 0
fi

echo "Temporary boot may fail or require forced shutdown, but does not flash a partition."
printf 'To attempt a RAM-only boot, type the device serial exactly (%s): ' "$serial"
read -r confirmation
if [ "$confirmation" != "$serial" ]; then
    echo "Cancelled: no changes to the phone."
    exit 4
fi
exec "$fastboot" -s "$serial" boot "$image"