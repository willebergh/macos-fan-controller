#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/build/FanControl.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/FanControl "$APP/Contents/MacOS/FanControl"
cp packaging/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
echo "Open with: open \"$APP\""
