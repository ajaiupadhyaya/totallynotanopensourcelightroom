#!/bin/zsh
# Build, sign with Developer ID, notarize, staple, and package PhotoEditor.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in the login keychain.
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
#      Application; or upload signing/DeveloperID.certSigningRequest at
#      developer.apple.com → Certificates → +, then double-click the .cer.)
#   2. Notary credentials, either:
#      - an App Store Connect API key: put AuthKey_<KEYID>.p8 in signing/
#        (Users and Access → Integrations → App Store Connect API), or
#      - a keychain profile: xcrun notarytool store-credentials notary \
#          --apple-id <apple-id> --team-id <team-id> --password <app-specific>
#
# Usage: scripts/notarize.sh
# Output: build/PhotoEditor-<version>.zip — notarized, stapled, ready to ship.

set -euo pipefail
cd "$(dirname "$0")/.."

ISSUER_ID="${ISSUER_ID:-ab3b85b2-eac0-40bd-a7e6-393008512993}"

# 1. Find the Developer ID identity.
IDENTITY=$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
  echo "error: no 'Developer ID Application' certificate in the keychain." >&2
  echo "Create one first (see the header of this script)." >&2
  exit 1
fi
echo "Signing identity: $IDENTITY"

# 2. Release build.
xcodegen generate
xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/Release build | tail -2

APP=build/Release/Build/Products/Release/PhotoEditor.app
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")

# 3. Sign with hardened runtime and a secure timestamp.
codesign --force --deep --options runtime --timestamp \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# 4. Zip and submit for notarization.
ZIP="build/PhotoEditor-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

P8=$(ls signing/AuthKey_*.p8 2>/dev/null | head -1 || true)
if [[ -n "$P8" ]]; then
  KEY_ID=$(basename "$P8" .p8 | sed 's/^AuthKey_//')
  echo "Notarizing with API key $KEY_ID…"
  xcrun notarytool submit "$ZIP" --wait \
    --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER_ID"
else
  echo "Notarizing with keychain profile 'notary'…"
  xcrun notarytool submit "$ZIP" --wait --keychain-profile notary
fi

# 5. Staple the ticket to the app and re-zip (the zip itself can't be stapled).
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 6. Prove Gatekeeper accepts it.
spctl --assess --type execute --verbose "$APP"
echo "Done: $ZIP is notarized, stapled, and ready to ship."
