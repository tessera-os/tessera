#!/bin/sh
# Host controls and kernel/task preflight. A guest I/O result is never inferred.
set -eu
cd "$(dirname "$0")"
task=../../tarwin-task
swift test
swift build --package-path "$task" --product tarwin-task
host="$(swift build --package-path "$task" --show-bin-path)/tarwin-task"
runner="$(swift build --show-bin-path)/hosted-io-e2e"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
swift ../../trfs/tests/fixtures/make-system-image.swift "$tmp"
"$runner" preflight "$host" "$tmp/system.trfs"
# H1 permits data-only boot with an absent system volume. This check does not.
if "$runner" preflight "$host" "$tmp/absent.trfs" >"$tmp/missing" 2>&1; then
  echo "preflight accepted a missing system image" >&2
  exit 1
fi
grep -Fx 'preflight failed: didNotBoot' "$tmp/missing"
dd if=/dev/zero of="$tmp/system.trfs" bs=4096 count=2 conv=notrunc 2>/dev/null
if "$runner" preflight "$host" "$tmp/system.trfs" >"$tmp/damaged" 2>&1; then
  echo "preflight accepted damaged anchors" >&2
  exit 1
fi
grep -Fx 'preflight failed: measure' "$tmp/damaged"
