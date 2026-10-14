#!/bin/zsh
# Create a versioned, Apple Silicon release asset from the Swift package.
set -e
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./make-release.sh <version> [build-number]}"
BUILD_NUMBER="${2:-1}"
ARCH="$(uname -m)"
ASSET="AIUsageBar-v${VERSION}-macos-${ARCH}.dmg"

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" ./make-app.sh
rm -f "$ASSET" "$ASSET.sha256"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto AIUsageBar.app "$STAGE/AIUsageBar.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AI Usage Bar" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$ASSET" >/dev/null
shasum -a 256 "$ASSET" > "$ASSET.sha256"
echo "Built $PWD/$ASSET"
