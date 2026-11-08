#!/usr/bin/env bash
# Compile the explicit Inlay -> PID 1 -> confined Notes document-open slice.
# This is a source/type validation gate, NOT a guest boot or runtime test.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
kira="${KIRA:-$HOME/.klf/bin/kira}"
export KLF_SYSROOT="${KLF_SYSROOT:-$HOME/.tessera-build/sysroot/aarch64-linux-gnu.cross}"

if [[ ! -x "$kira" ]]; then
    printf 'Kira toolchain not executable: %s\n' "$kira" >&2
    exit 2
fi
if [[ ! -d "$KLF_SYSROOT" ]]; then
    printf 'Tessera cross sysroot not available: %s\n' "$KLF_SYSROOT" >&2
    exit 2
fi

cd "$root"
for package in libtessera init tessera-ui inlay notes; do
    printf '\n[document-open] checking %s for aarch64-unknown-tessera\n' "$package"
    "$kira" check --target aarch64-unknown-tessera "tessera-packages/$package"
done

printf '\n[document-open] checking isolated document protocol regressions\n'
"$kira" check --target aarch64-unknown-tessera tessera-packages/libtessera/tests/document_kik --test
printf '\n[document-open] checking Inlay search, preview and recent-document regressions\n'
"$kira" check --target aarch64-unknown-tessera tessera-packages/inlay/tests/operations_kik --test
printf '\n[document-open] all source checks passed; guest boot and behavior remain unverified\n'