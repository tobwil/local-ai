#!/bin/zsh
# Baut "KI lokal.app" (KI/lokal) nach app/build/ und startet sie mit --run.
# Mit --install: zusätzlich nach /Applications kopieren, dort für Links (kilokal://) anmelden und starten.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
xcodebuild -project LocalAI.xcodeproj -scheme LocalAI -configuration Release \
  -derivedDataPath build/DerivedData -quiet build
rm -rf "build/KI lokal.app"
cp -R "build/DerivedData/Build/Products/Release/KI lokal.app" build/
# Mit der Developer ID signieren (falls vorhanden): Die Identität bleibt über Builds gleich, macOS fragt dann nicht
# nach jedem Build erneut nach dem Zugriff auf den Schlüsselbund (API-Schlüssel, Heimnetz-Schlüssel).
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --options runtime --entitlements Resources/KI-lokal.entitlements --sign "$IDENTITY" "build/KI lokal.app"
fi
# Nur diese Kopie soll Links (kilokal://) und Aufträge bekommen – Zwischenstände von Xcode bei macOS abmelden.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for stale in build/DerivedData/Build/Products/*/"KI lokal.app" build/dmg/"KI lokal.app"; do
  [[ -d "$stale" ]] && $LSREGISTER -u "$stale" 2>/dev/null || true
done
if [[ "${1:-}" == "--install" ]]; then
  INSTALLED="/Applications/KI lokal.app"
  # Laufende App beenden (sie stoppt dabei die Engine), dann ersetzen.
  osascript -e 'tell application id "de.kisruptiv.kilokal" to quit' 2>/dev/null || true
  for _ in {1..20}; do pgrep -qf "KI lokal.app/Contents/MacOS/KI lokal$" || break; sleep 0.5; done
  rm -rf "$INSTALLED"
  ditto "build/KI lokal.app" "$INSTALLED"
  $LSREGISTER -u "build/KI lokal.app" 2>/dev/null || true
  $LSREGISTER -f "$INSTALLED"
  echo "→ installiert: $INSTALLED"
  open "$INSTALLED"
  exit 0
fi

$LSREGISTER -f "build/KI lokal.app"
echo "→ $(pwd)/build/KI lokal.app"

if [[ "${1:-}" == "--run" ]]; then
  open "build/KI lokal.app"
fi
