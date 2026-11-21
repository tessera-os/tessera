#!/bin/bash
set -euo pipefail
APP=""
REPORT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) [[ $# -ge 2 ]] || { echo "--app requires a path" >&2; exit 2; }; APP="$2"; shift 2 ;;
        --report) [[ $# -ge 2 ]] || { echo "--report requires a path" >&2; exit 2; }; REPORT="$2"; shift 2 ;;
        *) echo "Usage: $0 [--app <bundle>] [--report <file>]" >&2; exit 2 ;;
    esac
done
if [[ -n "$APP" && "$APP" != /* ]]; then APP="$PWD/$APP"; fi
if [[ -n "$REPORT" && "$REPORT" != /* ]]; then REPORT="$PWD/$REPORT"; fi
cd "$(dirname "$0")/.."
run_tests() (
    set -e
    swift test
    if [[ -z "$APP" ]]; then
        scripts/build-app.sh
        APP="$PWD/build/Tessera.app"
    else
        swift build -c release --arch arm64 --product tessera-mac-test
    fi
    "$(swift build -c release --arch arm64 --show-bin-path)/tessera-mac-test" "$APP"
)
if [[ -n "$REPORT" ]]; then
    mkdir -p "$(dirname "$REPORT")"
    set +e
    run_tests 2>&1 | tee "$REPORT"
    result=${PIPESTATUS[0]}
    set -e
    if [[ $result -eq 0 ]]; then echo "PASS: Tessera hosted app tests" | tee -a "$REPORT"
    else echo "FAIL: Tessera hosted app tests (exit $result)" | tee -a "$REPORT"; fi
    exit "$result"
fi
run_tests
