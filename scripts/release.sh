#!/bin/sh
# Builds a release in build/release/<version>/ (PRD-06):
#   Riftway-<version>.dmg   first download: drag Riftway to Applications
#   Riftway-<version>.zip   what the app's updater downloads
#   feed.json, feed.json.sig  the signed feed (app, runtimes, profiles)
#
#   scripts/release.sh [--runtime work/runtime/artifacts/<version>.tar.gz]... [--notes "TEXT"]
#
# The version comes from app/Info.plist. Signing needs the release key
# (riftway-release keygen; $RIFTWAY_RELEASE_KEY or ~/.riftway/release-signing.key).
# Upload the folder's files together to the address in RiftwayFeedURL.
set -eu

cd "$(dirname "$0")/.."
RUNTIMES=""
NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --runtime) RUNTIMES="$RUNTIMES --runtime $2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 64 ;;
    esac
done

plist() { /usr/libexec/PlistBuddy -c "Print $1" app/Info.plist; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MINIMUM="$(plist LSMinimumSystemVersion)"
if ! grep -q "static let version = \"$VERSION\"" Sources/RiftwayCore/BottleSetup.swift; then
    echo "Riftway.version in Sources/RiftwayCore/BottleSetup.swift is not $VERSION (app/Info.plist)" >&2
    exit 1
fi

CONFIG=release scripts/build-app.sh
swift build -c release --product riftway-release
TOOL="$(swift build -c release --show-bin-path)/riftway-release"

OUT="build/release/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --keepParent build/Riftway.app "$OUT/Riftway-$VERSION.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/Riftway.app "$STAGE/Riftway.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Riftway $VERSION" -srcfolder "$STAGE" -fs APFS -format UDZO "$OUT/Riftway-$VERSION.dmg"

if [ -n "$NOTES" ]; then
    # shellcheck disable=SC2086
    "$TOOL" feed --out "$OUT" --app-zip "$OUT/Riftway-$VERSION.zip" --app-version "$VERSION" --build "$BUILD" \
        --minimum-macos "$MINIMUM" --notes "$NOTES" $RUNTIMES --profiles profiles
else
    # shellcheck disable=SC2086
    "$TOOL" feed --out "$OUT" --app-zip "$OUT/Riftway-$VERSION.zip" --app-version "$VERSION" --build "$BUILD" \
        --minimum-macos "$MINIMUM" $RUNTIMES --profiles profiles
fi
"$TOOL" sign "$OUT/feed.json"
"$TOOL" verify "$OUT/feed.json"
echo "Release $VERSION in $OUT"
