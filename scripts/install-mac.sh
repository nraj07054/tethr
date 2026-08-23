#!/usr/bin/env bash
# Builds Tethr.app and installs it to /Applications, replacing any running copy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build-mac.sh"

echo "==> Quitting any running Tethr"
osascript -e 'tell application "Tethr" to quit' 2>/dev/null || true
sleep 1
pkill -x Tethr 2>/dev/null || true

echo "==> Installing to /Applications"
rm -rf /Applications/Tethr.app
cp -R "$ROOT/mac/Tethr.app" /Applications/Tethr.app

open /Applications/Tethr.app
echo "==> Tethr is running"
