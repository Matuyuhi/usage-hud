#!/bin/sh
# Release ビルドして /Applications の usage-hud を入れ替え、再起動する
set -eu
cd "$(dirname "$0")/.."

xcodebuild -project usage-hud.xcodeproj -scheme usage-hud -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build -allowProvisioningUpdates build

pkill -f "usage-hud.app/Contents/MacOS/usage-hud" || true
rm -rf /Applications/usage-hud.app
ditto build/Build/Products/Release/usage-hud.app /Applications/usage-hud.app
open /Applications/usage-hud.app
echo "installed: /Applications/usage-hud.app"
