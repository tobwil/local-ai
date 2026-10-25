#!/bin/zsh
# Baut "KI lokal.app" (KI/lokal) nach app/build/ und startet sie mit --run.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
xcodebuild -project LocalAI.xcodeproj -scheme LocalAI -configuration Release \
  -derivedDataPath build/DerivedData -quiet build
rm -rf "build/KI lokal.app"
cp -R "build/DerivedData/Build/Products/Release/KI lokal.app" build/
echo "→ $(pwd)/build/KI lokal.app"

if [[ "${1:-}" == "--run" ]]; then
  open "build/KI lokal.app"
fi
