#!/bin/bash
# Build Sidebar.app (native, WebKit) and optionally install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Sidebar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sidebar "$APP/Contents/MacOS/Sidebar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sidebar</string>
  <key>CFBundleDisplayName</key><string>Sidebar</string>
  <key>CFBundleIdentifier</key><string>studio.persimmons.sidebar</string>
  <key>CFBundleExecutable</key><string>Sidebar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
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
codesign --force --deep -s - "$APP"
echo "built $APP"
if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Sidebar"' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Sidebar.app
  ditto "$APP" /Applications/Sidebar.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Sidebar.app
  echo "installed /Applications/Sidebar.app"
fi
