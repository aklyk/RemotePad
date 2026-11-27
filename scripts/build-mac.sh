#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product RemotePadMac
BIN_DIR=$(swift build -c release --show-bin-path)
OUTPUT_DIR="${REMOTEPAD_OUTPUT_DIR:-$PWD/build}"
APP_PATH="$OUTPUT_DIR/RemotePad Mac.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/RemotePadMac" "$APP_PATH/Contents/MacOS/RemotePadMac"
cp Resources/Mac-Info.plist "$APP_PATH/Contents/Info.plist"
cp Resources/RemotePad.icns "$APP_PATH/Contents/Resources/RemotePad.icns"
/bin/sh scripts/build-usb-relay.sh "$APP_PATH/Contents/MacOS/RemotePadUSBRelay"

# Pin the first identity locally. Silently changing it invalidates Accessibility grants.
IDENTITY_FILE="$PWD/.remotepad-signing-identity"
SIGN_IDENTITY="${REMOTEPAD_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" && -f "$IDENTITY_FILE" ]]; then
    SIGN_IDENTITY="$(cat "$IDENTITY_FILE")"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | /usr/bin/awk '/Apple Development:/ {print $2; exit}')"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/MacOS/RemotePadUSBRelay"
codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
printf '%s\n' "$SIGN_IDENTITY" > "$IDENTITY_FILE"
printf 'Built: %s\n' "$APP_PATH"
