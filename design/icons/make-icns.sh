#!/bin/bash
# Builds AppIcon.icns from the pixel-rim SVG using only the Command Line Tools (swiftc + iconutil).
set -euo pipefail
cd "$(dirname "$0")"

SRC="12-pixel.svg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -swift-version 5 render-icon.swift -o "$TMP/render"
mkdir "$TMP/AppIcon.iconset"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  "$TMP/render" "$SRC" "$TMP/AppIcon.iconset/icon_${spec#*:}.png" "${spec%%:*}"
done
iconutil -c icns "$TMP/AppIcon.iconset" -o ../../AppIcon.icns
echo "Wrote AppIcon.icns"
