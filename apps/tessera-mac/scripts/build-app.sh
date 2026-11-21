#!/bin/bash
set -euo pipefail
APP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) [[ $# -ge 2 ]] || { echo "--output requires a path" >&2; exit 2; }; APP="$2"; shift 2 ;;
        *) echo "Usage: $0 [--output <bundle>]" >&2; exit 2 ;;
    esac
done
if [[ -n "$APP" && "$APP" != /* ]]; then APP="$PWD/$APP"; fi
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP="${APP:-$PWD/build/Tessera.app}"
SERVICE="$APP/Contents/XPCServices/com.tessera.tarwind.xpc"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$SERVICE/Contents/MacOS"
cp "$BIN/Tessera" "$APP/Contents/MacOS/Tessera"
cp "$BIN/tarwind" "$SERVICE/Contents/MacOS/tarwind"
cp "$BIN/tarwin-task" "$SERVICE/Contents/MacOS/tarwin-task"
printf 'TESSERA SYSTEM IMAGE PLACEHOLDER\n' > "$APP/Contents/Resources/system.timg"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tessera.Tessera</string>
<key>CFBundleExecutable</key><string>Tessera</string>
<key>CFBundleName</key><string>Tessera</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$SERVICE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tessera.tarwind</string>
<key>CFBundleExecutable</key><string>tarwind</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements scripts/entitlements.plist "$SERVICE/Contents/MacOS/tarwin-task"
codesign --force --sign - --options runtime --entitlements scripts/entitlements.plist "$SERVICE"
codesign --force --sign - --options runtime --entitlements scripts/entitlements.plist "$APP"
echo "Built $APP"
