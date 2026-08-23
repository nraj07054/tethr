#!/usr/bin/env bash
# Builds a signed release APK, taking the password from the Keychain so it is
# never typed, pasted, or left in shell history.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYSTORE="${KEYSTORE:-$HOME/.tethr/tethr-release.jks}"
ALIAS="${ALIAS:-tethr}"
SERVICE="tethr-release-keystore"

[ -e "$KEYSTORE" ] || { echo "No keystore at $KEYSTORE — run scripts/make-release-key.sh" >&2; exit 1; }

PASSWORD="$(security find-generic-password -w -s "$SERVICE" 2>/dev/null)" || {
  echo "No password in the Keychain for service $SERVICE" >&2; exit 1; }

TETHR_KEYSTORE="$KEYSTORE" \
TETHR_KEYSTORE_PASSWORD="$PASSWORD" \
TETHR_KEY_ALIAS="$ALIAS" \
TETHR_KEY_PASSWORD="$PASSWORD" \
  "$ROOT/android/gradlew" -p "$ROOT/android" assembleRelease

APK="$ROOT/android/app/build/outputs/apk/release/app-release.apk"
echo "==> Built $APK"
APKSIGNER=$(find "$HOME/Library/Android/sdk/build-tools" -name apksigner 2>/dev/null | sort | tail -1)
[ -n "$APKSIGNER" ] && "$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | grep "certificate DN" || true
