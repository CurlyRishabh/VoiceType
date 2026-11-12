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
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$OUT/icon1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/icon1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$OUT/icon1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> signing (ad-hoc) with sandbox entitlements"
codesign --force --sign - "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign - --entitlements Resources/VoiceType.entitlements "$APP"
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
hdiutil create -volname "VoiceType" -srcfolder "$STAGE" -ov -format UDZO "$OUT/VoiceType.dmg" >/dev/null
rm -rf "$STAGE" "$ICONSET"
echo "==> done: $OUT/VoiceType.dmg ($(du -h "$OUT/VoiceType.dmg" | cut -f1))"
