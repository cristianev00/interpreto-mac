#!/bin/bash
# Builds build/Interpreto.app (release, Apple silicon) and signs it for this Mac.
#   ./scripts/build-app.sh             build
#   ./scripts/build-app.sh --install   build, then replace /Applications/Interpreto.app
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/fetch-vendor.sh
swift build -c release --arch arm64
APP=build/Interpreto.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
BIN="$APP/Contents/MacOS/Interpreto"
cp "$(swift build -c release --arch arm64 --show-bin-path)/Interpreto" "$BIN"
# The development rpath points into this project; the app uses Contents/Frameworks only.
install_name_tool -delete_rpath "$PWD/Vendor/sherpa-onnx/lib" "$BIN" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/silero_vad.onnx "$APP/Contents/Resources/"
# sherpa-onnx (SenseVoice and voice-activity detection) and the ONNX runtime it uses.
cp Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib Vendor/sherpa-onnx/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/"
# Signed with the personal "Interpreto Local Signing" certificate when it's in the keychain, so
# macOS keeps the microphone permission across updates (an ad-hoc signature changes with every
# build). For other Macs: sign with a Developer ID and notarize.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"Interpreto Local Signing"/{print $2; exit}')
SIGN=${IDENTITY:--}
echo "signing with: ${IDENTITY:-ad-hoc}"
codesign --force --sign "$SIGN" "$APP"/Contents/Frameworks/*.dylib
codesign --force --sign "$SIGN" --options runtime --entitlements Resources/Interpreto.entitlements "$APP"
codesign --verify --deep "$APP"
# Make sure every library the app needs is inside it (a missing one stops it at launch).
for lib in $(otool -L "$BIN" | awk '/@rpath/{print $1}'); do
    name=${lib#@rpath/}
    [ -e "$APP/Contents/Frameworks/$name" ] || { echo "missing in app: $name"; exit 1; }
done
du -sh "$APP"
if [ "${1:-}" = "--install" ]; then
    pkill -f "/Applications/Interpreto.app/Contents/MacOS/Interpreto" || true
    rm -rf /Applications/Interpreto.app
    ditto "$APP" /Applications/Interpreto.app
    rm -rf "$APP"                      # keep a single Interpreto on this Mac
    echo "installed in /Applications"
fi
