#!/bin/zsh
# Baut KI/lokal als signierte DMG.
#   Scripts/make-dmg.sh                  → signiert mit der ersten „Developer ID Application“-Identität (sonst ad hoc)
#   SIGN_IDENTITY="…" Scripts/make-dmg.sh → bestimmte Identität
#   NOTARY_PROFILE=name Scripts/make-dmg.sh → zusätzlich notarisieren (xcrun notarytool store-credentials name …)
set -euo pipefail
cd "${0:A:h}/.."

./Scripts/build.sh
APP="build/KI lokal.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"

if [[ -n "$IDENTITY" ]]; then
  echo "Signiere mit: $IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --entitlements Resources/KI-lokal.entitlements --sign "$IDENTITY" "$APP"
else
  echo "Keine Developer ID gefunden – Ad-hoc-Signatur (andere Macs zeigen eine Gatekeeper-Warnung)."
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

STAGE=build/dmg
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
DMG="build/KI-lokal-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "KI lokal $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
[[ -n "$IDENTITY" ]] && codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "→ $(pwd)/$DMG"
