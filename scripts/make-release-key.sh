#!/usr/bin/env bash
# Creates the signing key that release APKs are signed with, and stores its
# password in the macOS login Keychain.
#
# An Android signing key is permanent: every future update must be signed with
# the same one, anyone holding it can publish something that installs over your
# app, and losing it means never being able to update an installed copy again.
# So the key lives outside the repository, readable only by you, and its
# password is never written to a file — the Keychain holds it, encrypted at
# rest and unlocked only by your login.
set -euo pipefail

KEYSTORE="${KEYSTORE:-$HOME/.tethr/tethr-release.jks}"
ALIAS="${ALIAS:-tethr}"
SERVICE="tethr-release-keystore"

if [ -e "$KEYSTORE" ]; then
  echo "A keystore already exists at $KEYSTORE"
  echo "Refusing to overwrite it. Losing this key means you can never update an"
  echo "installed copy of Tethr again — delete it deliberately if you must."
  exit 1
fi

mkdir -p "$(dirname "$KEYSTORE")"
chmod 700 "$(dirname "$KEYSTORE")"

# Generated rather than chosen: a signing key is never typed by a human, so a
# memorable password buys nothing and costs entropy.
PASSWORD="$(head -c 48 /dev/urandom | base64 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-40)"

echo "==> Creating a 25-year signing key at $KEYSTORE"
# Fed on stdin, not as -storepass, so the password never appears in the process
# list where any other process on the machine could read it.
printf '%s\n%s\n\n' "$PASSWORD" "$PASSWORD" | keytool -genkeypair \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity 9125 \
  -dname "CN=Tethr, OU=Tethr, O=Tethr, C=IN" >/dev/null

chmod 600 "$KEYSTORE"

echo "==> Storing the password in your login Keychain"
security add-generic-password -a "$ALIAS" -s "$SERVICE" -w "$PASSWORD" -U
unset PASSWORD

cat <<NOTES

==> Done.

  Keystore   $KEYSTORE          (mode 600, outside the repo)
  Password   macOS Keychain, service "$SERVICE"
  Alias      $ALIAS

Read the password back at any time with:

  security find-generic-password -w -s $SERVICE

Build a signed APK locally:

  scripts/build-release-apk.sh

Publish signed APKs from CI by adding four repository secrets:

  base64 -i "$KEYSTORE" | gh secret set KEYSTORE_BASE64
  security find-generic-password -w -s $SERVICE | gh secret set KEYSTORE_PASSWORD
  printf '%s' "$ALIAS" | gh secret set KEY_ALIAS
  security find-generic-password -w -s $SERVICE | gh secret set KEY_PASSWORD

Back the keystore up somewhere you will still have in years — an encrypted
external drive, or a password manager that takes file attachments. The Keychain
holds the password, not the key itself, and neither is recoverable if lost.
NOTES
