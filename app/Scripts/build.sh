#!/bin/zsh
# Baut "Local AI.app" nach app/build/ und startet sie mit --run.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
xcodebuild -project LocalAI.xcodeproj -scheme LocalAI -configuration Release \
  -derivedDataPath build/DerivedData -quiet build
rm -rf "build/Local AI.app"
cp -R "build/DerivedData/Build/Products/Release/Local AI.app" build/
echo "→ $(pwd)/build/Local AI.app"

if [[ "${1:-}" == "--run" ]]; then
  open "build/Local AI.app"
fi
