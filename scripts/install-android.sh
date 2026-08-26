#!/usr/bin/env bash
# Builds the Android app and installs it to the connected device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${VARIANT:-debug}"

if ! command -v adb >/dev/null; then
  echo "adb not found. Install Android platform-tools and try again." >&2
  exit 1
fi
if [ -z "$(adb devices | sed -n '2p')" ]; then
  echo "No device connected. Enable USB debugging and plug the phone in." >&2
  exit 1
fi

# Capitalised for the Gradle task name. Spelled out rather than "${VARIANT^}",
# which is a bash 4 expansion: macOS still ships bash 3.2, where it is a syntax
# error and this script could never install anything.
TASK="$(printf '%s' "$VARIANT" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"

# A local build outranks any release, so it can always be installed over one.
# Release builds take their version from the tag, which left a dev build looking
# like a downgrade and Android refusing it outright — and -d does not help,
# because that only covers downgrading a *debuggable* app.
#
# This does not get a debug build over a *release-signed* one: Android will not
# swap signing keys, whatever the version says. Uninstall first (which clears
# the pairing), or wait for the next release, which is signed with the same key
# and installs over it cleanly.
export TETHR_VERSION="${TETHR_VERSION:-dev}"
export TETHR_VERSION_CODE="${TETHR_VERSION_CODE:-99000}"

echo "==> Building ($VARIANT)"
( cd "$ROOT/android" && ./gradlew "assemble$TASK" )

APK=$(find "$ROOT/android/app/build/outputs/apk/$VARIANT" -name '*.apk' | head -1)
echo "==> Installing $APK"
adb install -r -d "$APK"
adb shell am start -n com.nikhilraj.tethr/.MainActivity >/dev/null
echo "==> Tethr is running on the phone"
