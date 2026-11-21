#!/bin/sh
# Exercises portable algorithms on the host. Not a kernel build or a §34 run.
set -eu
tarwin=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for pkg in object syscall sched sync ipc loader security; do
    "${KIRA:-kira}" build --emit bin -o "$out/$pkg" "$tarwin/tarwin-$pkg/tests/host"
    "$out/$pkg"
    echo "host: tarwin-$pkg passed"
done
