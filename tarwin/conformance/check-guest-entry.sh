#!/bin/sh
# Fails on the first missing or failed emulator diagnostic. No reference
# inventory or release receipts are produced by emulator diagnostics.
set -eu
hv=$(CDPATH= cd -- "$(dirname -- "$0")/../tarwin-hv" && pwd)
for target in arm x64 rv64; do
    sh "$hv/tests/StageTwoHarness/run.sh" "$target"
    sh "$hv/tests/StageTwoHarness/run.sh" "$target" kernel
    if [ "$target" != x64 ]; then sh "$hv/tests/StageTwoHarness/run.sh" "$target" irq; fi
done
sh "$hv/tests/VMXStageTwoProbe/bochs.sh"
