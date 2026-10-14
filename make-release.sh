#!/bin/zsh
# Create a versioned, Apple Silicon release asset from the Swift package.
set -e
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./make-release.sh <version> [build-number]}"
BUILD_NUMBER="${2:-1}"
ARCH="$(uname -m)"
ASSET="AIUsageBar-v${VERSION}-macos-${ARCH}.zip"

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" ./make-app.sh
rm -f "$ASSET" "$ASSET.sha256"
ditto -c -k --keepParent AIUsageBar.app "$ASSET"
shasum -a 256 "$ASSET" > "$ASSET.sha256"
echo "Built $PWD/$ASSET"
