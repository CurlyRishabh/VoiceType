#!/usr/bin/env bash
# Downloads the pinned sherpa-onnx macOS arm64 shared libraries + headers and verifies the checksum.
set -euo pipefail
VERSION="2.0.1"
SHA256="4fcc6c77c8d8d2e2f04cfdc17c6fd224c01469b78529370eb9d8e0e5ec97ac79"
NAME="sherpa-onnx-v${VERSION}-osx-arm64-shared-no-tts"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/sherpa-onnx"
if [[ -f "$DEST/lib/libsherpa-onnx-c-api.dylib" ]]; then echo "sherpa-onnx already present"; exit 0; fi
TMP="$(mktemp -d)"
curl -fL --retry 3 -o "$TMP/a.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${NAME}.tar.bz2"
[[ "$(shasum -a 256 "$TMP/a.tar.bz2" | awk '{print $1}')" == "$SHA256" ]] || { echo "checksum mismatch" >&2; exit 1; }
tar xjf "$TMP/a.tar.bz2" -C "$TMP"
mkdir -p "$ROOT/vendor"
rm -rf "$DEST"
mv "$TMP/$NAME" "$DEST"
rm -rf "$DEST/bin" "$TMP"
echo "sherpa-onnx ${VERSION} ready in $DEST"
