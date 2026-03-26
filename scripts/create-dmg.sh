#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# create-dmg.sh
#
# Packages Kerwan.app into a distributable DMG with a custom background image,
# an Applications folder symlink, and sensible icon placement.
#
# Usage
#   bash scripts/create-dmg.sh <path/to/Kerwan.app> <output.dmg> [background.png]
#
# Dependencies
#   create-dmg   (brew install create-dmg)
#
# The resulting DMG is NOT notarized — that step happens in the release workflow
# after this script completes.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP_PATH="${1:?Usage: $0 <Kerwan.app> <output.dmg> [background.png]}"
OUTPUT_DMG="${2:?Usage: $0 <Kerwan.app> <output.dmg> [background.png]}"
BACKGROUND="${3:-}"   # optional — defaults to solid colour if not supplied

# ── Validate inputs ─────────────────────────────────────────────────────────
if [[ ! -d "$APP_PATH" ]]; then
  echo "::error::App bundle not found: $APP_PATH"
  exit 1
fi

if ! command -v create-dmg &>/dev/null; then
  echo "::error::create-dmg not found. Run: brew install create-dmg"
  exit 1
fi

# Remove any stale output DMG from a previous run
rm -f "$OUTPUT_DMG"

echo "▸ App:        $APP_PATH"
echo "▸ Output DMG: $OUTPUT_DMG"

# ── Stage the source directory ───────────────────────────────────────────────
# create-dmg requires a source folder, not a direct .app path
STAGING_DIR="$(mktemp -d /tmp/dmg-staging-XXXXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_PATH" "$STAGING_DIR/Kerwan.app"

# ── Build create-dmg argument list ──────────────────────────────────────────
CREATE_DMG_ARGS=(
  --volname       "Kerwan"
  --window-pos    200 120
  --window-size   600 400
  --icon-size     128
  --icon          "Kerwan.app" 150 185
  --hide-extension "Kerwan.app"
  --app-drop-link 450 185
  --no-internet-enable
)

# Only pass --background if a file was supplied and exists
if [[ -n "$BACKGROUND" && -f "$BACKGROUND" ]]; then
  echo "▸ Background: $BACKGROUND"
  CREATE_DMG_ARGS+=(--background "$BACKGROUND")
else
  echo "▸ Background: none (solid Finder default)"
fi

# Optional: sign the DMG immediately if CERT_NAME is available
# (The release workflow signs separately to keep this script self-contained)
if [[ -n "${CERT_NAME:-}" ]]; then
  echo "▸ Will codesign DMG with: $CERT_NAME"
  CREATE_DMG_ARGS+=(--codesign "$CERT_NAME")
fi

# ── Create DMG ───────────────────────────────────────────────────────────────
echo "▸ Running create-dmg…"
create-dmg "${CREATE_DMG_ARGS[@]}" "$OUTPUT_DMG" "$STAGING_DIR"

# create-dmg exits 2 when the codesign step is skipped (no identity found),
# but still produces a valid DMG — treat exit 2 as success here.
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 && $EXIT_CODE -ne 2 ]]; then
  echo "::error::create-dmg failed (exit $EXIT_CODE)"
  exit $EXIT_CODE
fi

ls -lh "$OUTPUT_DMG"
echo "▸ DMG created: $OUTPUT_DMG"
