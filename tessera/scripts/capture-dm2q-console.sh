#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <log-file>" >&2
    exit 2
fi

log_file=$1
log_dir=$(dirname "$log_file")
mkdir -p "$log_dir"

printf 'Waiting for the dm2q USB ACM console; saving to %s\n' "$log_file" >&2
while :; do
    found=0
    for port in /dev/cu.usbmodem*; do
        [ -c "$port" ] || continue
        found=1
        printf '[%s] connected to %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$port" >> "$log_file"
        if stty -f "$port" 115200 raw -echo; then
            cat "$port" >> "$log_file" || true
        fi
        printf '[%s] disconnected from %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$port" >> "$log_file"
        sleep 1
    done
    if [ "$found" -eq 0 ]; then sleep 1; fi
done
