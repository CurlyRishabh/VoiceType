#!/usr/bin/env bash
# Downloads the pinned whisper.cpp Apple xcframework (Metal GPU, Apple silicon) and verifies the checksum.
# Build b5454 is the same commit as the v1.9.5 release (d1be6fde).
set -euo pipefail
BUILD="b5454"
SHA256="e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/whisper.xcframework"
if [[ -f "$DEST/Info.plist" ]]; then echo "whisper.cpp already present"; exit 0; fi
TMP="$(mktemp -d)"
curl -fL --retry 3 -o "$TMP/a.zip" "https://github.com/ggml-org/whisper.cpp/releases/download/${BUILD}/whisper-${BUILD}-xcframework.zip"
[[ "$(shasum -a 256 "$TMP/a.zip" | awk '{print $1}')" == "$SHA256" ]] || { echo "checksum mismatch" >&2; exit 1; }
ditto -x -k "$TMP/a.zip" "$TMP/x"
mkdir -p "$ROOT/vendor"
rm -rf "$DEST"
mv "$TMP/x/build-apple/whisper.xcframework" "$DEST"
rm -rf "$TMP"
echo "whisper.cpp ${BUILD} ready in $DEST"
