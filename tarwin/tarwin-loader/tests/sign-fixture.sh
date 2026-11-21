#!/bin/bash
# Run on an actual W0 intermediate and the archive containing its unsigned kernel.
set -euo pipefail
bin=${SIGN_FIXTURE:?set SIGN_FIXTURE to the built executable}
machine=${1:?machine} train=${2:?train} tir=${3:?TIR version} image=${4:?ELF} archive=${5:?TIRA}
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
umask 077
reject() { if "$@" > /dev/null 2>&1; then echo "unexpected acceptance: $1 $2" >&2; exit 1; fi; }
"$bin" init "$d/dev"
"$bin" init "$d/other"
"$bin" enroll "$d/dev" "$d/pin"
[[ $(wc -c < "$d/pin") -eq 2036 ]]
"$bin" sign-image "$d/dev" "$machine" "$train" "$tir" "$image" "$d/signed"
"$bin" verify-image "$d/dev" "$machine" "$train" "$tir" "$d/signed"
reject "$bin" verify-image "$d/dev" "$machine" "$train" "$tir" "$image"
reject "$bin" verify-image "$d/other" "$machine" "$train" "$tir" "$d/signed"
reject "$bin" verify-image "$d/dev" "$machine" 99.12.5 "$tir" "$d/signed"
"$bin" sign-set "$d/dev" "$archive" "$d/sig"
"$bin" verify-set "$d/dev" "$archive" "$d/sig"
reject "$bin" verify-set "$d/other" "$archive" "$d/sig"
# Change one byte without touching length or any other field.
flip() {
    cp "$1" "$2"
    local off=$3
    local b=$(od -An -tu1 -j "$off" -N1 "$2")
    printf "\\$(printf '%03o' "$((b^1))")" | dd of="$2" bs=1 seek="$off" conv=notrunc status=none
}
end=$(wc -c < "$d/sig")
for pos in $((end-3373)) $((end-3309)) 8; do
    flip "$d/sig" "$d/bad" "$pos"
    reject "$bin" verify-set "$d/dev" "$archive" "$d/bad"
done
flip "$archive" "$d/bad" 24
reject "$bin" verify-set "$d/dev" "$d/bad" "$d/sig"
flip "$d/signed" "$d/bad" 512
reject "$bin" verify-image "$d/dev" "$machine" "$train" "$tir" "$d/bad"
echo "QEMU host signing, independent enrollment and mutation tests passed"
