#!/bin/bash
set -euo pipefail
APP=""
INIT_IMAGE=""
LIBTESSERA_IMAGE=""
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || { echo "$1 requires a path" >&2; exit 2; }
    case "$1" in
        --output) APP="$2" ;;
        --init-image) INIT_IMAGE="$2" ;;
        --libtessera-image) LIBTESSERA_IMAGE="$2" ;;
        *) echo "Usage: $0 [--output <bundle>] [--init-image <file> --libtessera-image <file>]" >&2; exit 2 ;;
    esac
    shift 2
done
if [[ -n "$APP" && "$APP" != /* ]]; then APP="$PWD/$APP"; fi
if [[ -n "$INIT_IMAGE" || -n "$LIBTESSERA_IMAGE" ]]; then
    if [[ ! -f "$INIT_IMAGE" || ! -f "$LIBTESSERA_IMAGE" ]]; then
        echo "Both --init-image and --libtessera-image must name existing files" >&2
        exit 2
    fi
    if [[ "$INIT_IMAGE" != /* ]]; then INIT_IMAGE="$PWD/$INIT_IMAGE"; fi
    if [[ "$LIBTESSERA_IMAGE" != /* ]]; then LIBTESSERA_IMAGE="$PWD/$LIBTESSERA_IMAGE"; fi
fi
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
TASK_PACKAGE="$PWD/../../tarwin/tarwin-task"
swift build --package-path "$TASK_PACKAGE" -c release --arch arm64 --product tarwin-task
TASK_BIN="$(swift build --package-path "$TASK_PACKAGE" -c release --arch arm64 --show-bin-path)"
APP="${APP:-$PWD/build/Tessera.app}"
SERVICE="$APP/Contents/XPCServices/com.tessera.tarwind.xpc"
SYSTEM_ROOT=""
if [[ -n "$INIT_IMAGE" ]]; then
    PACK_DIR="$(mktemp -d)"
    trap 'rm -rf "$PACK_DIR"' EXIT
    SYSTEM_ROOT="$("$BIN/tessera-pack-system" "$INIT_IMAGE" "$LIBTESSERA_IMAGE" "$PACK_DIR/system.timg")"
    [[ "$SYSTEM_ROOT" =~ ^[0-9a-f]{64}$ ]]
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$SERVICE/Contents/MacOS" "$SERVICE/Contents/Resources"
cp "$BIN/Tessera" "$APP/Contents/MacOS/Tessera"
cp "$BIN/tarwind" "$SERVICE/Contents/MacOS/tarwind"
cp "$TASK_BIN/tarwin-task" "$SERVICE/Contents/MacOS/tarwin-task"
if [[ -f "$APP/Contents/Resources/system.timg" ]] &&
   [[ "$(head -c 32 "$APP/Contents/Resources/system.timg")" == "TESSERA SYSTEM IMAGE PLACEHOLDER" ]]; then
    rm "$APP/Contents/Resources/system.timg"
fi
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
<key>NSMicrophoneUsageDescription</key><string>Tessera uses your microphone for hosted apps.</string>
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
SYSTEM_IMAGE="$SERVICE/Contents/Resources/system.timg"
rm -f "$SYSTEM_IMAGE"
if [[ -n "$SYSTEM_ROOT" ]]; then
    cp "$PACK_DIR/system.timg" "$SYSTEM_IMAGE"
    chmod 444 "$SYSTEM_IMAGE"
    /usr/libexec/PlistBuddy -c "Add :TesseraSystemRoot string $SYSTEM_ROOT" "$SERVICE/Contents/Info.plist"
fi
IDENTITY="${TESSERA_CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --options runtime --entitlements scripts/entitlements.plist "$SERVICE/Contents/MacOS/tarwin-task"
codesign --force --sign "$IDENTITY" --options runtime --entitlements scripts/entitlements.plist "$SERVICE"
codesign --force --sign "$IDENTITY" --options runtime --entitlements scripts/entitlements.plist "$APP"
echo "Built $APP"
