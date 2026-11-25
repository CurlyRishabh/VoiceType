#!/usr/bin/env bash
# Builds VoiceType.app (ad-hoc signed, App Sandbox, no network entitlement) and VoiceType.dmg.
# Usage: scripts/build-dmg.sh            (from the mac/ folder or anywhere)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build"
APP="$OUT/VoiceType.app"
PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

echo "==> sherpa-onnx libraries"
scripts/fetch-sherpa.sh
echo "==> whisper.cpp framework"
scripts/fetch-whisper-cpp.sh
echo "==> Silero VAD (bundled)"
scripts/fetch-vad.sh
echo "==> speaker models (bundled)"
scripts/fetch-diarization.sh

echo "==> unit tests"
TEST_FLAGS=()
[[ -d "$PLUGINS" ]] && TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
swift test "${TEST_FLAGS[@]}" 2>&1 | grep -E "Test run with|error:|✘" || true
swift test "${TEST_FLAGS[@]}" >/dev/null 2>&1 || { echo "Unit tests failed" >&2; exit 1; }

echo "==> release build"
swift build -c release --arch arm64

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/VoiceType" "$APP/Contents/MacOS/VoiceType"
cp vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib vendor/sherpa-onnx/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/"
# whisper.cpp: Apple-silicon slice only, without headers (not needed at run time).
WFW="$APP/Contents/Frameworks/whisper.framework"
ditto --arch arm64 vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$WFW"
rm -rf "$WFW/Headers" "$WFW/Modules" "$WFW/Versions/A/Headers" "$WFW/Versions/A/Modules"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Silero VAD ships in the app (0.6 MB), so users only import the speech model.
mkdir -p "$APP/Contents/Resources/models/vad"
cp vendor/silero_vad.onnx "$APP/Contents/Resources/models/vad/"
# Speaker models (about 30 MB) for telling the other people on a call apart.
mkdir -p "$APP/Contents/Resources/models/diarization"
cp vendor/diarization/segmentation.onnx vendor/diarization/embedding.onnx "$APP/Contents/Resources/models/diarization/"
cp Resources/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"

# App icon
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$OUT/icon1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/icon1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$OUT/icon1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# A stable identity keeps macOS permissions (mic, Accessibility, Input Monitoring) across rebuilds;
# ad-hoc ("-") changes identity every build, so macOS asks again. Override: SIGN_ID="Name" scripts/build-dmg.sh
SIGN_ID="${SIGN_ID:-VoiceType Local}"
security find-identity -p codesigning | grep -qF "\"$SIGN_ID\"" || SIGN_ID="-"
echo "==> signing ($([[ $SIGN_ID == "-" ]] && echo "ad-hoc: permissions reset on every build" || echo "$SIGN_ID")) with sandbox entitlements"
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN_ID" --entitlements Resources/VoiceType.entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "==> privacy check"
ENT="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
grep -q "com.apple.security.app-sandbox" <<<"$ENT" || { echo "PRIVACY: sandbox entitlement missing" >&2; exit 1; }
if grep -q "com.apple.security.network" <<<"$ENT"; then echo "PRIVACY: network entitlement present!" >&2; exit 1; fi
echo "    App Sandbox: ON · network entitlements: NONE · entitlements:"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -oE "com\.apple\.security\.[a-z.-]+" | sed 's/^/      /'

echo "==> disk image"
STAGE="$OUT/dmg"
rm -rf "$STAGE" "$OUT/VoiceType.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/Read Me.md"
cp Resources/THIRD_PARTY_NOTICES.txt "$STAGE/Third-Party Notices.txt"
hdiutil create -volname "VoiceType" -srcfolder "$STAGE" -ov -format UDZO "$OUT/VoiceType.dmg" >/dev/null
rm -rf "$STAGE" "$ICONSET"
echo "==> done: $OUT/VoiceType.dmg ($(du -h "$OUT/VoiceType.dmg" | cut -f1))"
