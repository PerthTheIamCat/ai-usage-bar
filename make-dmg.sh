#!/bin/zsh
# Package AIUsageBar.app into a drag-to-Applications disk image with a styled
# Finder window (background, arrow, fixed icon positions).
# Usage: ./make-dmg.sh <output.dmg>
# Set DMG_PLAIN=1 to skip the Finder styling (no GUI session needed).
set -e
cd "$(dirname "$0")"

OUT="${1:?Usage: ./make-dmg.sh <output.dmg>}"
APP=AIUsageBar.app
VOL="AI Usage Bar"
[[ -d "$APP" ]] || { echo "$APP not found. Run ./make-app.sh first." >&2; exit 1; }

WORK="$(mktemp -d)"
MOUNT="/Volumes/$VOL"
cleanup() {
  [[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
[[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true

style_window() {
  # Retina-aware background: one TIFF carrying the 1x and 2x images.
  mkdir -p "$MOUNT/.background"
  tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png \
    -out "$MOUNT/.background/background.tiff" 2>/dev/null \
    || cp Resources/dmg/background.png "$MOUNT/.background/background.tiff"
  osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "AIUsageBar.app" of container window to {170, 215}
    set position of item "Applications" of container window to {490, 215}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
}

if [[ -n "${DMG_PLAIN:-}" ]]; then
  STAGE="$WORK/stage"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$OUT"
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"
else
  RW="$WORK/rw.dmg"
  hdiutil create -size 40m -fs HFS+ -volname "$VOL" -ov "$RW" >/dev/null
  hdiutil attach "$RW" -mountpoint "$MOUNT" -nobrowse >/dev/null
  cp -R "$APP" "$MOUNT/"
  ln -s /Applications "$MOUNT/Applications"
  # A styling failure (no Finder session, e.g. some CI shells) must not break
  # the release: the plain layout is still a working installer.
  style_window || echo "warning: Finder styling failed; the dmg will use the plain layout" >&2
  sync
  hdiutil detach "$MOUNT" >/dev/null
  rm -f "$OUT"
  hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
fi

# Sign the image itself when a real identity is configured, so Gatekeeper can
# also assess the disk image (needed before notarizing the .dmg).
if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$OUT"
fi
echo "Built $PWD/$OUT"
