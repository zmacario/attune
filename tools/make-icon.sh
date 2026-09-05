#!/bin/bash
# Renders Resources/AppIcon.icns from tools/make-icon.swift.
#
# Separate from build.sh because it is slow (it compiles a second binary) and the icon
# changes far less often than the app. build.sh calls it only when the source is newer
# than the .icns.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swiftc -O -o "$WORK/make-icon" tools/make-icon.swift
mkdir -p "$WORK/AppIcon.iconset"
"$WORK/make-icon" "$WORK/AppIcon.iconset" >/dev/null
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns

echo "Wrote Resources/AppIcon.icns"
