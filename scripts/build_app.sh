#!/bin/zsh
# Builds build/MacDashboard.app (release, ad-hoc signed).
# Usage: scripts/build_app.sh [--install | --zip]
#   --install  copies the app to /Applications
#   --zip      writes build/MacDashboard-<version>.zip for a GitHub release (ditto keeps the signature)
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/MacDashboard.app"

cd "$ROOT"
swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/MacDashboard" "$APP/Contents/MacOS/MacDashboard"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.sjk.MacDashboard "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--zip" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
    ZIP="$ROOT/build/MacDashboard-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP"
fi

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/MacDashboard.app"
    pkill -x MacDashboard 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "Installed $DEST"
fi
