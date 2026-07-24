#!/bin/bash
# Build unde and assemble unde.app — a proper bundle with Info.plist so
# LSUIElement, the menu bar item, and Accessibility all behave. Ad-hoc signed
# for local development (a stable Developer ID identity avoids re-authorising
# Accessibility on every rebuild; see PLAN M7).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/unde.app"

echo "▸ swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/unde"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/unde"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "▸ code signing (ad-hoc)"
codesign --force --sign - --options runtime --timestamp=none "$APP" 2>/dev/null || \
  codesign --force --sign - "$APP"

echo "✓ built $APP"
