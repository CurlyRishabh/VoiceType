#!/usr/bin/env bash
# Downloads the pinned Silero VAD model (0.6 MB, MIT) that ships inside VoiceType.app, so users don't
# have to download it themselves. Verifies the checksum.
set -euo pipefail
SHA256="9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/silero_vad.onnx"
if [[ -f "$DEST" ]]; then echo "silero_vad.onnx already present"; exit 0; fi
TMP="$(mktemp -d)"
curl -fL --retry 3 -o "$TMP/vad.onnx" "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
[[ "$(shasum -a 256 "$TMP/vad.onnx" | awk '{print $1}')" == "$SHA256" ]] || { echo "checksum mismatch" >&2; exit 1; }
mkdir -p "$ROOT/vendor"
mv "$TMP/vad.onnx" "$DEST"
rm -rf "$TMP"
echo "silero_vad.onnx ready in $DEST"
