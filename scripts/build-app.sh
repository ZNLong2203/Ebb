#!/bin/bash
# Builds build/Ebb.app (release, ad-hoc signed).
#   VERSION=1.2.0 scripts/build-app.sh   set the version shown in Finder/About (default 0.0.0-dev)
#   scripts/build-app.sh --run          launch the app afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"

if [ ! -f Resources/AppIcon.icns ]; then
    scripts/make-icns.sh
fi

swift build -c release

APP="build/Ebb.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Ebb "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"

echo "Built $APP ($VERSION)"

if [ "${1:-}" = "--run" ]; then
    pkill -x Ebb 2>/dev/null || true
    open "$APP"
fi
