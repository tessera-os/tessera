#!/bin/sh
# Builds the pinned external references and runs the conformance tests.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
venv=${TRFS_XREF_VENV:-$scratch/venv}
[ -x "$venv/bin/python" ] || python3 -m venv "$venv"
"$venv/bin/pip" -q install 'cryptography==44.0.3'
cd "$here"
"$venv/bin/python" tools/xts_ref.py version
TRFS_XREF_PYTHON="$venv/bin/python" swift test --scratch-path "$scratch/build" "$@"
