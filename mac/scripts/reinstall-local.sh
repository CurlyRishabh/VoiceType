#!/usr/bin/env bash
# Clean local reinstall for testing: quits VoiceType, clears every macOS permission it has
# (stale entries from differently signed builds look "on" but don't apply), builds, installs
# to ~/Applications and opens it so setup asks for each permission once.
# Keeps the speech model, the Dictionary, settings and meetings.
set -euo pipefail
cd "$(dirname "$0")/.."
ID=dev.offline.voicetype.mac
APP="$HOME/Applications/VoiceType.app"

osascript -e "quit app id \"$ID\"" 2>/dev/null || true
sleep 2
pkill -x VoiceType 2>/dev/null || true

[[ "${SKIP_BUILD:-0}" == 1 ]] || scripts/build-dmg.sh
tccutil reset All "$ID" || true

rm -rf "$APP"
mkdir -p "$HOME/Applications"
ditto build/VoiceType.app "$APP"
rm -rf build/VoiceType.app # one copy only, so System Settings can't show two "VoiceType"s
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign -d -r- "$APP" 2>&1 | tail -1
# Setup opens again so every step is checked with the new permissions.
defaults write "$HOME/Library/Containers/$ID/Data/Library/Preferences/$ID" onboarding_step -int 0
open "$APP"
echo "Installed $APP. Grant Microphone, Accessibility and Input Monitoring in setup; System Audio Recording is asked on the first meeting."
