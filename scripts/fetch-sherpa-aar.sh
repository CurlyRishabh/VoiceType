#!/usr/bin/env bash
# Downloads the pinned sherpa-onnx Android AAR into the project-local Maven repo and verifies it.
# Run once on your computer before the first build (the build fails with a clear error otherwise).
set -euo pipefail

VERSION="2.0.1"
SHA256="a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/sherpa-onnx-${VERSION}.aar"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/third_party/maven/com/k2fsa/sherpa/onnx/sherpa-onnx/${VERSION}"
DEST="$DEST_DIR/sherpa-onnx-${VERSION}.aar"

mkdir -p "$DEST_DIR"

verify() {
  local actual
  actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  [[ "$actual" == "$SHA256" ]]
}

if [[ -f "$DEST" ]] && verify "$DEST"; then
  echo "sherpa-onnx ${VERSION} AAR already present and verified."
  exit 0
fi

echo "Downloading $URL"
curl -fL --retry 3 -o "$DEST.part" "$URL"
if ! verify "$DEST.part"; then
  echo "Checksum mismatch for downloaded AAR; refusing to use it." >&2
  rm -f "$DEST.part"
  exit 1
fi
mv "$DEST.part" "$DEST"
echo "Saved and verified: $DEST"
