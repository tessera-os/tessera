#!/bin/sh
# Run the q35 cold-remount test with an isolated software TPM.
set -eu
: "${1:?usage: sh test-measured-volume.sh BLOCKQTEST QEMU_SYSTEM_X86_64}"
: "${2:?missing QEMU executable}"
dir=$(mktemp -d /tmp/tarwin-pcr11.XXXXXX)
pid=
cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  fi
  rm -rf "$dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
swtpm socket --tpm2 --tpmstate "dir=$dir" --ctrl "type=unixio,path=$dir/ctrl,mode=0600" &
pid=$!
i=0
while [ ! -S "$dir/ctrl" ]; do
  kill -0 "$pid" && [ "$i" -lt 100 ] || exit 1
  i=$((i+1))
  sleep 0.05
done
if [ "${TARWIN_QTEST_SIGNED_SET+x}" = x ]; then
  TARWIN_QTEST_CORPUS=$(dirname "$0")/../../../../tarwin-loader/w0/Tests/TarwinW0Tests/SystemRootCorpus
  export TARWIN_QTEST_CORPUS
  TARWIN_QTEST_TPM_SOCKET="$dir/ctrl" "$1" "$2" --trfs-signed-pcr11
  exit
elif [ "${TARWIN_QTEST_ROOT+x}" != x ]; then
  swift "$(dirname "$0")/../../../../trfs/tests/fixtures/make-system-image.swift" "$dir"
  TARWIN_QTEST_ROOT=$dir/system.trfs.root
fi
export TARWIN_QTEST_ROOT
TARWIN_QTEST_TPM_SOCKET="$dir/ctrl" "$1" "$2" --trfs-nvme-pcr11
