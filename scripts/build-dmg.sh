#!/usr/bin/env bash
# Packages Tethr.app into Tethr-macOS.dmg for downloading from a browser.
#
# The image holds the app and a link to /Applications, so installing is the
# usual drag across. Pass --skip-build to package an app already built by
# scripts/build-mac.sh (the release workflow does, to avoid compiling twice).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/mac/Tethr.app"
DMG="${DMG:-$ROOT/Tethr-macOS.dmg}"

[ "${1:-}" = "--skip-build" ] || "$ROOT/scripts/build-mac.sh"
[ -x "$APP/Contents/MacOS/Tethr" ] || { echo "No built app at $APP" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging the disk image"
# ditto, not cp: it keeps the bundle's symlinks and code signature intact.
ditto "$APP" "$STAGE/Tethr.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Tethr" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

# Fails the build if anything went wrong inside the image, rather than
# publishing a DMG whose app will not launch.
echo "==> Verifying"
hdiutil verify "$DMG" >/dev/null
MNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
codesign --verify --deep --strict "$MNT/Tethr.app" && STATUS=0 || STATUS=$?
hdiutil detach "$MNT" -quiet
[ "$STATUS" -eq 0 ] || { echo "Signature broken inside the DMG" >&2; exit 1; }

echo "==> Built $DMG"
