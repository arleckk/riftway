#!/bin/sh
# Uploads build/release/<version>/ (from scripts/release.sh) to GitHub Releases
# as tag v<version>, as a draft: review it on GitHub, then publish it with
#   gh release edit v<version> --draft=false
# Only the newest published release (not drafts or pre-releases) is "latest",
# which is where the app looks for feed.json.
#
#   scripts/publish-release.sh [--source FILE]...
#
# --source attaches the runtime's corresponding source (Wine is LGPL 2.1),
# e.g. the pinned crossover-sources tarball the runtime was built from.
set -eu

cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" app/Info.plist)"
DIR="build/release/$VERSION"
[ -f "$DIR/feed.json.sig" ] || { echo "No signed release in $DIR; run scripts/release.sh first" >&2; exit 1; }
EXTRA=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source) EXTRA="$EXTRA $2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 64 ;;
    esac
done

# The feed must verify before anything is uploaded.
swift run -c release riftway-release verify "$DIR/feed.json"
NOTES="$(/usr/bin/python3 -I -c 'import json,sys; print((json.load(open(sys.argv[1])).get("app") or {}).get("notes") or "")' "$DIR/feed.json")"
# shellcheck disable=SC2086
gh release create "v$VERSION" --draft --title "Riftway $VERSION" --notes "${NOTES:-Riftway $VERSION}" "$DIR"/* $EXTRA
echo "Draft v$VERSION created. Publish it with: gh release edit v$VERSION --draft=false"
