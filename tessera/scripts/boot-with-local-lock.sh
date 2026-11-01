#!/usr/bin/env bash
# Boot-build entry point for source checkouts on filesystems where flock is
# unsupported (for example, Cairn). Redirects ONLY Kira's advisory lock to a
# local filesystem, never the source or produced artifacts. The original lock
# is restored on success, error and interruption. Not a substitute for a
# trusted build filesystem or a low-disk-space warning.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/boot-with-local-lock.sh --self-test
       scripts/boot-with-local-lock.sh --build [boot arguments ...]

--self-test: prove that the local advisory-lock workaround works, then verify
             the original lock was restored. Never starts a Tessera build.
--build:     check free space (at least 10 GiB on local build/cache volumes)
             and run `kira build boot -arch aarch64 -test` by default.
             Extra arguments replace the default boot arguments.
USAGE
}

mode=${1:-}
case "$mode" in
  --self-test|--build) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
train=$(cd "$script_dir/.." && pwd)
work="$train/.kira-build"
lock="$work/lock"
wrapper_guard="$work/.local-lock-wrapper"
local_root=${TMPDIR:-/private/tmp}
min_free_gib=10

command -v python3 >/dev/null 2>&1 || { echo 'python3 is required for the local lock probe' >&2; exit 1; }
if [[ "$mode" == --build ]]; then
  command -v kira >/dev/null 2>&1 || { echo 'kira is required on PATH' >&2; exit 1; }
  # The compiler's local cache and the temporary lock use local disk; check
  # both locations. Mac host disk space may differ greatly from remote Cairn.
  python3 - "$min_free_gib" "$local_root" "${KLF_HOME:-$HOME/.klf}" "$HOME/.cache/klf" <<'PY'
import os, sys
threshold = int(sys.argv[1]) * 1024**3
# Inspect each local build/cache filesystem without creating directories or
# modifying a developer's toolchain/cache just to perform the preflight.
checked_devices = set()
failed = False
for requested in sys.argv[2:]:
    path = os.path.abspath(requested)
    while not os.path.exists(path):
        parent = os.path.dirname(path)
        if parent == path:
            print(f'REFUSED: cannot inspect free space at {requested}', file=sys.stderr)
            sys.exit(1)
        path = parent
    stat = os.stat(path)
    if stat.st_dev in checked_devices:
        continue
    checked_devices.add(stat.st_dev)
    free = os.statvfs(path).f_bavail * os.statvfs(path).f_frsize
    print(f'Local free space at {path}: {free / 1024**3:.1f} GiB', flush=True)
    if free < threshold:
        print(f'REFUSED: less than {threshold / 1024**3:.0f} GiB available for a cold boot build', file=sys.stderr)
        failed = True
if failed:
    sys.exit(1)
PY
fi

mkdir -p "$work"
if ! mkdir "$wrapper_guard" 2>/dev/null; then
  echo 'REFUSED: another local-lock build wrapper holds the guard directory' >&2
  exit 1
fi

saved=''
local_lock=''
child_pid=''
lock_existed=0
installed_link=0
cleanup() {
  result=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$child_pid" ]]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  # Only remove the precise symlink installed by this process. A malformed
  # lock that existed BEFORE this invocation must never be deleted on error.
  if (( installed_link == 1 )) && [[ -L "$lock" ]]; then
    if [[ "$(readlink "$lock")" == "$local_lock" ]]; then
      rm -f "$lock"
    else
      echo "ERROR: build lock replaced by another process; leaving it untouched" >&2
      result=1
    fi
  fi
  if [[ -n "$saved" ]]; then
    if [[ -e "$lock" || -L "$lock" ]]; then
      echo "REFUSED: unexpected entry at $lock; original remains at $saved" >&2
      result=1
    elif [[ -f "$saved" ]]; then
      if mv "$saved" "$lock"; then
        echo 'Original Kira build lock restored'
      else
        echo "ERROR: original lock must be restored manually from $saved" >&2
        result=1
      fi
    else
      echo "ERROR: original build lock not found at $saved" >&2
      result=1
    fi
  fi
  [[ -z "$local_lock" ]] || rm -f "$local_lock"
  rmdir "$wrapper_guard" 2>/dev/null || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -L "$lock" || ( -e "$lock" && ! -f "$lock" ) ]]; then
  echo "REFUSED: $lock is not a regular, original lock file" >&2
  exit 1
fi

if [[ -f "$lock" ]]; then
  lock_existed=1
  saved="$work/lock.original.$$"
  if [[ -e "$saved" || -L "$saved" ]]; then
    echo "REFUSED: saved lock path already exists: $saved" >&2
    saved=''
    exit 1
  fi
  mv "$lock" "$saved"
else
  # A first build has no lock yet; we leave it absent on completion.
  saved=''
fi

local_lock=$(mktemp "$local_root/tessera-kira-lock.XXXXXX")
ln -s "$local_lock" "$lock"
installed_link=1
python3 - "$lock" <<'PY'
import fcntl, sys
with open(sys.argv[1], 'a+') as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
print('PASS: local advisory lock is usable through build-lock symlink')
PY

if [[ "$mode" == --self-test ]]; then
  echo 'PASS: self-test did not start a build'
  exit 0
fi
if (( $# == 0 )); then set -- boot -arch aarch64 -test; fi
printf 'Starting: kira build'; printf ' %s' "$@"; printf '\n'
(
  cd "$train"
  # exec replaces this child shell with Kira. The parent will then signal
  # the real driver process on interruption, not a shell that might leave
  # an orphaned build driver running with no lock.
  exec kira build "$@"
) &
child_pid=$!
# A failing child must still clear its PID before the EXIT trap runs. Never
# send an extra signal to a finished process whose PID may be recycled.
result=0
wait "$child_pid" || result=$?
child_pid=''
exit "$result"
