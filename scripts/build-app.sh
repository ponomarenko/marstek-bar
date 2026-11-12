#!/bin/bash
# Builds a release binary and wraps it into a menu-bar-only .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/MarstekBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MarstekBar "$APP/Contents/MacOS/MarstekBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MarstekBar</string>
    <key>CFBundleIdentifier</key><string>local.marstekbar</string>
    <key>CFBundleName</key><string>MarstekBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MarstekBar reads the battery status over the local network.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
