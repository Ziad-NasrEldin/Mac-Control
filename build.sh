#!/bin/zsh
# Builds VoiceControl.app next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)
APP=VoiceControl.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Frameworks $APP/Contents/Resources
cp "$BIN/VoiceControl" $APP/Contents/MacOS/VoiceControl
# Dynamic frameworks and resource bundles pulled in by FluidAudio.
for f in "$BIN"/*.framework(N); do cp -R "$f" $APP/Contents/Frameworks/; done
for b in "$BIN"/*.bundle(N); do cp -R "$b" $APP/Contents/Resources/; done
install_name_tool -add_rpath @executable_path/../Frameworks $APP/Contents/MacOS/VoiceControl 2>/dev/null || true
cat > $APP/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.voicecontrol</string>
  <key>CFBundleName</key><string>VoiceControl</string>
  <key>CFBundleExecutable</key><string>VoiceControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Voice Control listens while you hold its hotkey.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Voice Control turns your speech into a command.</string>
  <key>NSAppleEventsUsageDescription</key><string>Voice Control reads links and buttons on the current page and clicks them.</string>
</dict></plist>
EOF
# Sign with Developer ID (hardened runtime) so Accessibility access and Keychain access survive rebuilds
# and the app can be notarized; fall back to the local self-signed identity, then ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --entitlements VoiceControl.entitlements --sign "$IDENTITY" $APP
else
  IDENTITY=$(security find-identity -p codesigning | awk -F'"' '/Voice Control Local Signing/ {print $0; exit}' | awk '{print $2}')
  codesign --force --deep --sign "${IDENTITY:--}" $APP
fi
echo "Built $(pwd)/$APP"
