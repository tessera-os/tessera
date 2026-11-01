#!/usr/bin/env bash
# Local developer preflight, not an OS boot test. Safe for both the flat
# release train and Cairn's grouped workspace. Does not alter source files.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
train="$(cd "$script_dir/.." && pwd)"
# Both checkout shapes put the Tessera component directory beside desktop.
root="$(cd "$train/.." && pwd)"

passed=0
failed=0
warned=0
pass() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }
warn() { printf 'WARN  %s\n' "$1"; warned=$((warned + 1)); }

printf 'Tessera host preflight — %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf 'Train: %s\n' "$train"
printf 'Source root: %s\n' "$root"

for name in kira klf ksl; do
  if command -v "$name" >/dev/null 2>&1; then
    pass "$name: $(command -v "$name")"
  else
    fail "$name not found on PATH"
  fi
done
if command -v clang >/dev/null 2>&1; then
  pass "clang: $(command -v clang)"
else
  fail 'clang not found on PATH'
fi

if command -v python3 >/dev/null 2>&1; then
  # Use the same advisory-flock primitive as the compiler, with a disposable
  # file in the actual output directory. Never touch the build driver's lock.
  if [[ -d "$train/.kira-build" ]]; then
    if python3 - "$train/.kira-build" <<'PY'
import fcntl, os, pathlib, sys, tempfile
root = pathlib.Path(sys.argv[1])
try:
    with tempfile.NamedTemporaryFile(prefix='.lock-probe-', dir=root) as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(f.fileno(), fcntl.LOCK_UN)
except OSError as exc:
    print(f'lock probe failed: {exc}', file=sys.stderr)
    sys.exit(1)
PY
    then pass 'build output directory supports advisory locks'
    elif [[ -x "$script_dir/boot-with-local-lock.sh" ]] && "$script_dir/boot-with-local-lock.sh" --self-test >/dev/null 2>&1; then
      warn 'native advisory locks unsupported; guarded local-lock wrapper self-test passed (use scripts/boot-with-local-lock.sh --build when disk space permits)'
    else
      fail 'build output directory does not support advisory locks and local-lock workaround is unavailable'
    fi
  else
    warn 'no .kira-build directory yet; lock support not checked'
  fi
else
  warn 'python3 unavailable; cannot probe build-directory locking'
fi

assets_dir="$(cd "$train/.." && pwd)/platform-ui/Resources"
for name in Wallpaper.png WallpaperDark.png; do
  if [[ -f "$assets_dir/$name" ]]; then
    pass "local asset: $name"
  else
    warn "missing optional local asset: $assets_dir/$name"
  fi
done

if [[ "${1:-}" == '--tests' ]]; then
  if ! command -v kira >/dev/null 2>&1; then
    fail 'host tests skipped: kira unavailable'
  else
    suites=(
      'desktop/tests/layout_kik'
      'trash/tests/trash_kik'
      'inlay/tests/operations_kik'
      'app-registry/tests/registry_kik'
      'app-catalog/tests/catalog_kik'
    )
    for suite in "${suites[@]}"; do
      if [[ -d "$root/$suite" ]] && kira test "$root/$suite" >/dev/null 2>&1; then
        pass "host tests: $suite"
      else
        fail "host tests failed: $suite"
      fi
    done
  fi
fi

printf '\nResults: %d passed; %d warned; %d failed\n' "$passed" "$warned" "$failed"
if (( failed > 0 )); then exit 1; fi
exit 0
