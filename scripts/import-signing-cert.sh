#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# import-signing-cert.sh
#
# Creates a throw-away keychain, imports the Developer ID certificate, and
# configures it so that codesign / xcodebuild can access the key without a
# GUI passphrase prompt.
#
# Expected environment variables (all required)
#   APPLE_CERTIFICATE_P12       Base64-encoded .p12 certificate bundle
#   APPLE_CERTIFICATE_PASSWORD  Password that protects the .p12 file
#   KEYCHAIN_PASSWORD           Password for the throw-away keychain
#                               (any random string is fine — use $GITHUB_RUN_ID)
#
# Exported to GITHUB_ENV (available to subsequent steps)
#   KEYCHAIN_PATH               Path to the created keychain file
#   CERT_NAME                   Full name of the imported Developer ID cert
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${APPLE_CERTIFICATE_P12:?APPLE_CERTIFICATE_P12 is required}"
: "${APPLE_CERTIFICATE_PASSWORD:?APPLE_CERTIFICATE_PASSWORD is required}"
: "${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD is required}"

KEYCHAIN_NAME="build.keychain"
KEYCHAIN_PATH="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
CERT_P12_PATH="$(mktemp /tmp/cert-XXXXXXXX.p12)"

# Ensure the temp file is always removed
trap 'rm -f "$CERT_P12_PATH"' EXIT

echo "▸ Decoding certificate…"
echo "$APPLE_CERTIFICATE_P12" | base64 --decode > "$CERT_P12_PATH"

# Remove any stale keychain from a previous run (best-effort)
security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true

echo "▸ Creating temporary keychain: $KEYCHAIN_NAME"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security set-keychain-settings -t 7200 -u "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

# Add the new keychain to the search list (so xcodebuild / codesign find it)
# Preserve the existing list first
EXISTING_KEYCHAINS=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN_NAME" $EXISTING_KEYCHAINS

echo "▸ Importing Developer ID certificate…"
security import "$CERT_P12_PATH" \
  -k "$KEYCHAIN_NAME" \
  -P "$APPLE_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/productbuild

# Allow codesign to access the key without an interactive UI prompt
echo "▸ Setting key partition list…"
security set-key-partition-list \
  -S "apple-tool:,apple:,codesign:" \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_NAME"

# Discover the imported certificate's common name
CERT_NAME=$(security find-identity -v -p codesigning "$KEYCHAIN_NAME" \
  | grep "Developer ID Application" \
  | head -1 \
  | sed 's/.*"\(.*\)"/\1/')

if [[ -z "$CERT_NAME" ]]; then
  echo "::error::Developer ID Application certificate not found in keychain."
  echo "Certificates present:"
  security find-identity -v -p codesigning "$KEYCHAIN_NAME" || true
  exit 1
fi

echo "▸ Imported certificate: $CERT_NAME"

# Export variables to subsequent steps
{
  echo "KEYCHAIN_PATH=$KEYCHAIN_PATH"
  echo "CERT_NAME=$CERT_NAME"
} >> "$GITHUB_ENV"
