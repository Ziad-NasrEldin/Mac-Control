#!/bin/zsh
# Builds, notarizes and staples MacControl.app, then zips it for sharing.
# One-time setup (asks for an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials maccontrol-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
set -e
cd "$(dirname "$0")"
PROFILE=${NOTARY_PROFILE:-maccontrol-notary}
./build.sh
codesign --verify --strict --verbose=2 MacControl.app
ditto -c -k --keepParent MacControl.app MacControl-notarize.zip
xcrun notarytool submit MacControl-notarize.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple MacControl.app
spctl --assess --type execute --verbose MacControl.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" MacControl.app/Contents/Info.plist)
ditto -c -k --keepParent MacControl.app "MacControl-$VERSION.zip"
rm MacControl-notarize.zip
echo "Notarized: $(pwd)/MacControl-$VERSION.zip"
