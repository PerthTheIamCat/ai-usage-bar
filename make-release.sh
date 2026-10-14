#!/bin/zsh
# Create a versioned, Apple Silicon release asset from the Swift package.
set -e
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./make-release.sh <version> [build-number]}"
BUILD_NUMBER="${2:-1}"
ARCH="$(uname -m)"
ASSET="AIUsageBar-v${VERSION}-macos-${ARCH}.zip"
DMG="AIUsageBar-v${VERSION}-macos-${ARCH}.dmg"

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" ./make-app.sh
rm -f "$ASSET" "$ASSET.sha256"
ditto -c -k --keepParent AIUsageBar.app "$ASSET"
shasum -a 256 "$ASSET" > "$ASSET.sha256"

# Drag-to-Applications disk image, alongside the zip (the zip stays because
# the release workflow and updater consume it).
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R AIUsageBar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AI Usage Bar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG" > "$DMG.sha256"
echo "Built $PWD/$ASSET"
echo "Built $PWD/$DMG"
