#!/usr/bin/env bash
#
# NeuroSync — one-command release: archive → export → notarize → staple → DMG.
#
# This is a macOS app (CoreBluetooth). "Certification" for a macOS app distributed OUTSIDE the App
# Store = Developer ID signing + Apple notarization. There is no iOS target.
#
# PREREQS (one-time, human — see SHIPPING.md):
#   1. Apple Developer Program membership (Team 24QC7XFXVJ).
#   2. A "Developer ID Application" certificate for that team in your login keychain
#      (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application).
#   3. Notary credentials stored once:
#        xcrun notarytool store-credentials neurosync-notary \
#          --apple-id "<you@apple.id>" --team-id 24QC7XFXVJ --password "<app-specific-password>"
#      (or --key/--key-id/--issuer for an App Store Connect API key).
#
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="neurosync"
APP_NAME="neurosync"
TEAM_ID="24QC7XFXVJ"
NOTARY_PROFILE="${NOTARY_PROFILE:-neurosync-notary}"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/${APP_NAME}.app"
DMG="$BUILD_DIR/${APP_NAME}.dmg"

echo "▸ Clean"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

echo "▸ Archive (Release, Hardened Runtime)"
xcodebuild -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" archive

echo "▸ Export (Developer ID)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist dist/ExportOptions.plist \
  -exportPath "$EXPORT_DIR"

echo "▸ Verify signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "flags|Authority|TeamIdentifier" || true

echo "▸ Notarize the app"
ZIP="$BUILD_DIR/${APP_NAME}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "▸ Build DMG (styled: fixed window, drag-to-Applications)"
# create-dmg draws the fixed window — background art, icon size, and the two icon
# positions the arrow in scripts/dmg-background.png points between. Install it if missing.
if ! command -v create-dmg >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  brew install create-dmg || true
fi
rm -f "$DMG"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "NeuroSync" \
    --background "scripts/dmg-background.png" \
    --window-pos 200 120 --window-size 600 400 \
    --icon-size 112 \
    --icon "${APP_NAME}.app" 150 205 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 450 205 \
    --no-internet-enable \
    "$DMG" "$APP"
else
  # Last resort (no create-dmg, no Homebrew): a plain, unstyled DMG. Still installs fine.
  echo "  ⚠ create-dmg unavailable — building a plain DMG without the styled window."
  STAGE="$BUILD_DIR/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "NeuroSync" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

echo "▸ Sign + notarize + staple the DMG"
codesign --sign "Developer ID Application: ${TEAM_ID}" --timestamp "$DMG" || \
  codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "▸ Gatekeeper check (as a fresh Mac would see it)"
spctl -a -vv "$APP" || true
stapler validate "$DMG" || true

echo "✓ Done: $DMG"
