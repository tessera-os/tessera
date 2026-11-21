#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
trap 'exit 1' INT TERM
swift build --package-path "$here/metal-integration" --scratch-path "$build" --product metal-present-check
METAL_CHECK=$(swift build --package-path "$here/metal-integration" --scratch-path "$build" --show-bin-path)/metal-present-check
export METAL_CHECK
for target in arm rv64 x64; do
  printf 'QEMU debug guest: %s\n' "$target"
  sh "$here/../tarwin-hv/tests/StageTwoHarness/run.sh" "$target" metal
done
