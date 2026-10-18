#!/bin/bash
# Downloads and verifies the sherpa-onnx runtime used for SenseVoice (Chinese speech).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=v1.13.8
NAME=sherpa-onnx-$VERSION-osx-arm64-shared-lib
SHA256=ae77050cdae565496059d96f5ab33d77b397a0864282a4e4a26e3b3b3effb948
[ -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib ] && exit 0
mkdir -p Vendor/dl Vendor/sherpa-onnx
curl -fsSL -o "Vendor/dl/$NAME.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/$VERSION/$NAME.tar.bz2"
echo "$SHA256  Vendor/dl/$NAME.tar.bz2" | shasum -a 256 -c --quiet
tar -xjf "Vendor/dl/$NAME.tar.bz2" -C Vendor/dl
rm -rf Vendor/sherpa-onnx/lib && mv "Vendor/dl/$NAME/lib" Vendor/sherpa-onnx/lib
rm -rf Vendor/dl
echo "sherpa-onnx $VERSION ready"
