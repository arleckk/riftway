#!/bin/sh
# Builds app/Riftway.icns from app/icon/Riftway.svg (the source of the icon).
set -eu

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/png" "$WORK/Riftway.iconset"
swift scripts/render-icon.swift app/icon/Riftway.svg "$WORK/png" 16 32 64 128 256 512 1024
for size in 16 32 128 256 512; do
    cp "$WORK/png/$size.png" "$WORK/Riftway.iconset/icon_${size}x${size}.png"
    cp "$WORK/png/$((size * 2)).png" "$WORK/Riftway.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$WORK/Riftway.iconset" -o app/Riftway.icns
echo "Built app/Riftway.icns"
