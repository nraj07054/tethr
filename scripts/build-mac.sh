#!/usr/bin/env bash
# Builds Tethr.app from the Swift package.
#
# Swift Package Manager produces a bare executable, not an app bundle, so the
# bundle is assembled here: the binary and its resource bundle are copied into
# the Info.plist/icon skeleton kept in the repo, and the result is ad-hoc signed.
# Without a signature macOS refuses to launch it at all.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/mac/Tethr.app"
CONFIG="${CONFIG:-release}"

echo "==> Building Tethr ($CONFIG)"
swift build --package-path "$ROOT/mac" -c "$CONFIG"

BIN="$ROOT/mac/.build/$CONFIG/Tethr"
RES="$ROOT/mac/.build/$CONFIG/Tethr_Tethr.bundle"

echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tethr"
rm -rf "$APP/Contents/Resources/Tethr_Tethr.bundle"
[ -d "$RES" ] && cp -R "$RES" "$APP/Contents/Resources/"

# Ad-hoc ("-") rather than a Developer ID: this project has no Apple developer
# account. It is enough for the app to run locally; see the README for the
# Gatekeeper step a downloaded copy needs.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Built $APP"
