#!/bin/zsh
# Create versioned, Apple Silicon release assets (.zip for the Sparkle updater,
# .dmg for first-time installs) from the Swift package.
#
# When NOTARY_KEYCHAIN_PROFILE is set (a `notarytool store-credentials`
# profile) the app and the disk image are submitted to Apple's notary service
# and the tickets are stapled. This needs CODESIGN_IDENTITY to be a
# "Developer ID Application" identity; without it the assets are built
# unnotarized exactly as before.
set -e
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./make-release.sh <version> [build-number]}"
BUILD_NUMBER="${2:-1}"
ARCH="$(uname -m)"
BASE="AIUsageBar-v${VERSION}-macos-${ARCH}"
ASSET="$BASE.zip"
DMG="$BASE.dmg"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
}

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" ./make-app.sh

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  ditto -c -k --keepParent AIUsageBar.app notarize-app.zip
  notarize notarize-app.zip
  rm -f notarize-app.zip
  xcrun stapler staple AIUsageBar.app
fi

rm -f "$ASSET" "$ASSET.sha256" "$DMG" "$DMG.sha256"
ditto -c -k --keepParent AIUsageBar.app "$ASSET"
shasum -a 256 "$ASSET" > "$ASSET.sha256"

./make-dmg.sh "$DMG"
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi
shasum -a 256 "$DMG" > "$DMG.sha256"
echo "Built $PWD/$ASSET and $PWD/$DMG"
