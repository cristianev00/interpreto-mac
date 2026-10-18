#!/bin/bash
# Builds build/Interpreto.app (release, Apple silicon) and signs it for this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
APP=build/Interpreto.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/Interpreto" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ad-hoc signature (runs on this Mac). For other Macs: sign with a Developer ID and notarize.
codesign --force --sign - --options runtime --entitlements Resources/Interpreto.entitlements "$APP"
du -sh "$APP"
