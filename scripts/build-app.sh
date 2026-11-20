#!/usr/bin/env bash
# Baut dist/AgentSpeak.app (Universal: Apple Silicon + Intel) und ein ZIP zum Weitergeben.
#   scripts/build-app.sh                 -> ad-hoc signiert
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   -> mit Developer-ID signiert
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
BUILD=$(date +%Y%m%d%H%M)
APP="dist/AgentSpeak.app"

echo "▸ Kompiliere (Release, universal) …"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AgentSpeak"

echo "▸ App-Icon …"
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset && mkdir -p build
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

echo "▸ Bundle …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Leere .lproj-Ordner: macOS erkennt so Deutsch und Englisch (Systemdialoge, Sprache pro App)
mkdir -p "$APP/Contents/Resources/de.lproj" "$APP/Contents/Resources/en.lproj"
cp "$BIN" "$APP/Contents/MacOS/AgentSpeak"
cp hook/speak-summary.sh "$APP/Contents/Resources/speak-summary.sh"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "▸ Signieren …"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

ZIP="dist/AgentSpeak-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $APP"
echo "✓ $ZIP"
