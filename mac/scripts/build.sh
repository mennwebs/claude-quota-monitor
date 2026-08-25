#!/usr/bin/env bash
# Builds ClaudeQuota.app into dist/. Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claude Quota"
BUNDLE="dist/${APP_NAME}.app"
BUNDLE_ID="com.mennwebs.claude-quota-mac"
VERSION="1.0.0"

echo "▸ building release binary"
swift build -c release

echo "▸ assembling bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp .build/release/ClaudeQuota "$BUNDLE/Contents/MacOS/ClaudeQuota"

echo "▸ drawing icon"
swift scripts/make-icon.swift >/dev/null
iconutil -c icns dist/AppIcon.iconset -o "$BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf dist/AppIcon.iconset

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>ClaudeQuota</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock tile, no window on launch. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for a locally built app and for SMAppService to register
# it as a login item; it is not notarized and is not meant for distribution.
echo "▸ signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 || \
  echo "  (codesign failed — the app still runs, but 'เปิดตอนล็อกอิน' may not stick)"

echo "✓ $BUNDLE"
echo
echo "ติดตั้ง:  cp -R \"$BUNDLE\" /Applications/ && open \"/Applications/${APP_NAME}.app\""
