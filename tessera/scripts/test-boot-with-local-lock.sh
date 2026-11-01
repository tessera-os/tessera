#!/usr/bin/env bash
# Side-effect-isolated regression tests for the boot lock wrapper. All tests
# run from a temporary copy, never against Tessera's real .kira-build lock.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/private/tmp}/tessera-lock-tests.XXXXXX")
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/scripts" "$tmp/.kira-build"
cp "$script_dir/boot-with-local-lock.sh" "$tmp/scripts/boot-with-local-lock.sh"
wrapper="$tmp/scripts/boot-with-local-lock.sh"
lock="$tmp/.kira-build/lock"
guard="$tmp/.kira-build/.local-lock-wrapper"

# The self-test cannot change the original lock content or leave a symlink.
printf 'original sentinel\n' > "$lock"
"$wrapper" --self-test > "$tmp/working.log" 2>&1
test "$(cat "$lock")" = 'original sentinel'
test -f "$lock" && test ! -L "$lock"
test ! -e "$guard"
echo 'PASS original lock preservation and self-test'

# Two concurrent wrapper invocations cannot swap the same original lock.
mkdir "$guard"
if "$wrapper" --self-test > "$tmp/busy.log" 2>&1; then
  echo 'FAIL parallel wrapper incorrectly accepted' >&2; exit 1
fi
grep -q 'another local-lock build wrapper' "$tmp/busy.log"
rmdir "$guard"
test "$(cat "$lock")" = 'original sentinel'
echo 'PASS concurrent wrapper guard'

# Unexpected or linked original locks are never replaced.
rm "$lock"
ln -s /dev/null "$lock"
if "$wrapper" --self-test > "$tmp/link.log" 2>&1; then
  echo 'FAIL linked original lock incorrectly accepted' >&2; exit 1
fi
test -L "$lock"
test ! -e "$guard"
echo 'PASS linked original lock refusal'

# A first build without any existing lock leaves it absent on completion.
rm "$lock"
"$wrapper" --self-test > "$tmp/new.log" 2>&1
test ! -e "$lock" && test ! -L "$lock"
test ! -e "$guard"
echo 'PASS missing original lock restoration'

# Broken non-regular lock targets are rejected as well.
mkdir "$lock"
if "$wrapper" --self-test > "$tmp/dir.log" 2>&1; then
  echo 'FAIL directory lock incorrectly accepted' >&2; exit 1
fi
test -d "$lock"
test ! -e "$guard"
echo 'PASS nonregular lock refusal'

echo 'All boot lock wrapper self-tests passed.'
