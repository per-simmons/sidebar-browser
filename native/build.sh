#!/bin/bash
# Build Sidebar.app (native, WebKit) and optionally install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Sidebar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sidebar "$APP/Contents/MacOS/Sidebar"

# App icon (regenerated only when the drawing script changes)
if [[ ! -f Resources/AppIcon.icns || scripts/make-icon.swift -nt Resources/AppIcon.icns ]]; then
  TMP=$(mktemp -d); SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
  swift scripts/make-icon.swift "$TMP/master.png" >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/master.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/master.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sidebar</string>
  <key>CFBundleDisplayName</key><string>Sidebar</string>
  <key>CFBundleIdentifier</key><string>studio.persimmons.sidebar</string>
  <key>CFBundleExecutable</key><string>Sidebar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Pat Simmons</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCameraUsageDescription</key><string>Websites may ask to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites may ask to use the microphone.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Web site URL</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>HTML document</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>public.html</string></array>
  </dict></array>
</dict></plist>
PLIST
# Sign with Pat's personal Developer ID (team 39ZACC8H4P) so camera/mic permissions survive rebuilds.
IDENTITY="Developer ID Application: Patrick Simmons (39ZACC8H4P)"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --options runtime --timestamp=none --entitlements Resources/Sidebar.entitlements -s "$IDENTITY" "$APP"
else
  codesign --force -s - "$APP"
fi
echo "built $APP"
if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Sidebar"' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Sidebar.app
  ditto "$APP" /Applications/Sidebar.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Sidebar.app
  echo "installed /Applications/Sidebar.app"
fi
