#!/bin/sh
# Builds build/Riftway.app from the Swift package.
#
#   scripts/build-app.sh                 release build, ad hoc signature
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Helpers (the shim that URL bridges copy, and the CLI) go in Contents/Helpers
# and are signed before the outer bundle.
set -eu

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Riftway.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/RiftwayApp" "$APP/Contents/MacOS/Riftway"
cp "$BIN/riftway-shim" "$BIN/riftway" "$APP/Contents/Helpers/"

# Riftway Input: its own background app, so macOS asks for the Accessibility
# permission for it (not for Riftway or a game's bridge), once.
# INPUT_HELPER_FROM=<an installed Riftway Input.app> reuses it as is: with an
# ad hoc signature, macOS ties the Accessibility permission to the exact
# build, so an unchanged helper keeps it.
INPUT="$APP/Contents/Helpers/Riftway Input.app"
if [ -n "${INPUT_HELPER_FROM:-}" ]; then
    ditto "$INPUT_HELPER_FROM" "$INPUT"
else
mkdir -p "$INPUT/Contents/MacOS"
cp "$BIN/riftway-input" "$INPUT/Contents/MacOS/Riftway Input"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" app/Info.plist)"
cat > "$INPUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Riftway Input</string>
	<key>CFBundleIdentifier</key><string>com.riftway.input</string>
	<key>CFBundleName</key><string>Riftway Input</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHumanReadableCopyright</key><string>Riftway contributors. Apache License 2.0.</string>
</dict>
</plist>
PLIST
fi
cp LICENSE "$APP/Contents/Resources/LICENSE" 2>/dev/null || true
cp app/Riftway.icns "$APP/Contents/Resources/Riftway.icns"
# The launchers' own icons, for the Launchers page (app/Launchers/NOTICE.md).
mkdir -p "$APP/Contents/Resources/Launchers"
cp app/Launchers/*.png app/Launchers/NOTICE.md "$APP/Contents/Resources/Launchers/"
# Game profiles (PRD-05); the app and the CLI in Helpers read them from here.
mkdir -p "$APP/Contents/Resources/Profiles"
cp profiles/*.json "$APP/Contents/Resources/Profiles/"

if [ "$IDENTITY" = "-" ]; then
    sign() { codesign --force --sign - --timestamp=none "$@"; }
else
    sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }
fi
sign "$APP/Contents/Helpers/riftway-shim" "$APP/Contents/Helpers/riftway"
[ -n "${INPUT_HELPER_FROM:-}" ] || sign "$INPUT"
sign "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($CONFIG, signed $( [ "$IDENTITY" = "-" ] && echo "ad hoc" || echo "with $IDENTITY" ))"
