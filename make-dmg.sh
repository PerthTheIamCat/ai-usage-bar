#!/bin/zsh
# Package AIUsageBar.app into a drag-to-Applications disk image.
# Usage: ./make-dmg.sh <output.dmg>
set -e
cd "$(dirname "$0")"

OUT="${1:?Usage: ./make-dmg.sh <output.dmg>}"
APP=AIUsageBar.app
[[ -d "$APP" ]] || { echo "$APP not found. Run ./make-app.sh first." >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "AI Usage Bar" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"

# Sign the image itself when a real identity is configured, so Gatekeeper can
# also assess the disk image (needed before notarizing the .dmg).
if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$OUT"
fi
echo "Built $PWD/$OUT"
