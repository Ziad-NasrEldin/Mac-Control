#!/bin/zsh
# Builds, notarizes and staples VoiceControl.app, then zips it for sharing.
# One-time setup (asks for an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials voicecontrol-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
set -e
cd "$(dirname "$0")"
PROFILE=${NOTARY_PROFILE:-voicecontrol-notary}
./build.sh
codesign --verify --strict --verbose=2 VoiceControl.app
ditto -c -k --keepParent VoiceControl.app VoiceControl-notarize.zip
xcrun notarytool submit VoiceControl-notarize.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple VoiceControl.app
spctl --assess --type execute --verbose VoiceControl.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" VoiceControl.app/Contents/Info.plist)
ditto -c -k --keepParent VoiceControl.app "VoiceControl-$VERSION.zip"
rm VoiceControl-notarize.zip
echo "Notarized: $(pwd)/VoiceControl-$VERSION.zip"
