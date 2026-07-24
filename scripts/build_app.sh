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

# Sign with a STABLE identity so the Accessibility (TCC) grant survives rebuilds.
# Ad-hoc signatures pin their designated requirement to the code hash, which
# changes every build, so macOS drops the grant. A real certificate pins the
# requirement to the cert instead — grant once, keep it.
#
# Identity resolution: $UNDE_SIGN_IDENTITY if set, else the first codesigning
# identity in the keychain (Developer ID / Apple Development), else ad-hoc.
IDENTITY="${UNDE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n '1s/.*) \([0-9A-F]*\) .*/\1/p')"
fi

if [ -n "$IDENTITY" ]; then
  NAME="$(security find-identity -v -p codesigning | sed -n "s/.*$IDENTITY \"\(.*\)\"/\1/p" | head -1)"
  echo "▸ code signing with stable identity: ${NAME:-$IDENTITY}"
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "▸ code signing (ad-hoc fallback — AX grant will not persist across rebuilds)"
  codesign --force --sign - "$APP"
fi

echo "✓ built $APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|Identifier|Signature" | head -4 || true
