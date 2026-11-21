#!/bin/sh
# Host-only Kira tests. This does not produce a kernel or conformance result.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for pkg in kcore tarboot tarwin-boot tarwin-arch-aarch64 tarwin-arch-x64 tarwin-arch-rv64 tarwin-mm tarwin-time; do
    "${KIRA:-kira}" build --emit bin -o "$out/$pkg" "$root/$pkg/tests"
    "$out/$pkg"
    echo "host: $pkg passed"
done
if [ "${SWTPM_REPLAY:-0}" = 1 ]; then
    python3 "$root/tarwin-boot/tests/swtpm_replay.py" "$out/tarwin-boot"
fi
