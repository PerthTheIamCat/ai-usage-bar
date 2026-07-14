#!/bin/zsh
# Build AIUsageBar.app bundle from the Swift package.
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
swift build -c release
APP=AIUsageBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AIUsageBar "$APP/Contents/MacOS/AIUsageBar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.perth.aiusagebar</string>
    <key>CFBundleName</key><string>AI Usage Bar</string>
    <key>CFBundleExecutable</key><string>AIUsageBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
