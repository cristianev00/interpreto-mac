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
# llama.cpp (HY-MT2 translation) ships as a framework.
LLAMA=$(find .build/artifacts -path "*macos-arm64_x86_64/llama.framework" -maxdepth 6 | head -1)
ditto "$LLAMA" "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
# Ad-hoc signature (runs on this Mac). For other Macs: sign with a Developer ID and notarize.
codesign --force --sign - "$APP"/Contents/Frameworks/*.dylib
codesign --force --sign - --options runtime --entitlements Resources/Interpreto.entitlements "$APP"
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
