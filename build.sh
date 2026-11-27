#!/bin/bash
# Builds iStats.app and iStats.zip into ./dist
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/iStats.app"
rm -rf dist; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 main.m -o "$APP/Contents/MacOS/iStats" \
  -framework Cocoa -framework AVFoundation -framework AudioToolbox -framework IOKit -framework ServiceManagement -F/System/Library/PrivateFrameworks
cp assets/icon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>iStats</string>
<key>CFBundleIdentifier</key><string>io.github.istats</string>
<key>CFBundleExecutable</key><string>iStats</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
P
# A local signing certificate keeps the same identity across builds, so macOS keeps the Input Monitoring grant.
# Without one, sign ad hoc (every build then counts as a new app).
ID="iStats Local Signing"
security find-identity -p codesigning | grep -q "$ID" || ID=-
codesign --force --sign "$ID" "$APP"
ditto -c -k --keepParent "$APP" dist/iStats.zip
echo "Built dist/iStats.app and dist/iStats.zip"
