#!/bin/sh
# A read-only virtual disk, not a controller or physical-device test.
set -eu
runner=$(CDPATH= cd -- "$(dirname -- "$0")/../tarwin-hv/tests/StageTwoHarness" && pwd)/run.sh
for isa in arm x64 rv64; do
  for fault in none payload; do
    echo "$isa read-only virtual disk: $fault"
    STORAGE_FAULT=$fault sh "$runner" "$isa" storage
  done
done
