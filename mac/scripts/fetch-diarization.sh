#!/usr/bin/env bash
# Downloads the two pinned speaker-diarization models that ship inside VoiceType.app (about 30 MB),
# used to tell the other people on a call apart ("Speaker 1", "Speaker 2"…). Verifies checksums.
#   segmentation.onnx: pyannote segmentation-3.0, int8 export by sherpa-onnx (MIT, © CNRS)
#   embedding.onnx:    3D-Speaker CAM++ English (VoxCeleb), from sherpa-onnx (Apache-2.0)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/diarization"
SEG_SHA="d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d"
EMB_SHA="98daf9bcf1c8abf3db374fec4c27a5eda7c58705bb3f180d057b085a72a88bb5"
ok() { [[ -f "$1" && "$(shasum -a 256 "$1" | awk '{print $1}')" == "$2" ]]; }
if ok "$DEST/segmentation.onnx" "$SEG_SHA" && ok "$DEST/embedding.onnx" "$EMB_SHA"; then echo "diarization models already present"; exit 0; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DEST"
if ! ok "$DEST/segmentation.onnx" "$SEG_SHA"; then
  curl -fL --retry 3 -o "$TMP/seg.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
  tar xjf "$TMP/seg.tar.bz2" -C "$TMP"
  ok "$TMP/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx" "$SEG_SHA" || { echo "segmentation checksum mismatch" >&2; exit 1; }
  mv "$TMP/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx" "$DEST/segmentation.onnx"
fi
if ! ok "$DEST/embedding.onnx" "$EMB_SHA"; then
  curl -fL --retry 3 -o "$TMP/emb.onnx" "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx"
  ok "$TMP/emb.onnx" "$EMB_SHA" || { echo "embedding checksum mismatch" >&2; exit 1; }
  mv "$TMP/emb.onnx" "$DEST/embedding.onnx"
fi
echo "diarization models ready in $DEST"
