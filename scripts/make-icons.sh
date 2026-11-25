#!/bin/bash
# Regenerates the app icons from scripts/make-icons.swift and updates the
# checked-in assets:
#   iPadOSClient/WiredDisplayClient/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
#   macOSHost/Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wd-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp scripts/make-icons.swift "$WORK/main.swift"
xcrun swiftc -O -o "$WORK/make-icons" "$WORK/main.swift" macOSHost/Host/MenuBarIcon.swift
"$WORK/make-icons" "$WORK/out"
iconutil -c icns "$WORK/out/AppIcon.iconset" -o "$WORK/out/AppIcon.icns"
SET=iPadOSClient/WiredDisplayClient/Assets.xcassets/AppIcon.appiconset
cp "$WORK/out/AppIcon-iPad-1024.png" "$SET/AppIcon-1024.png"
ART=iPadOSClient/WiredDisplayClient/Assets.xcassets/AppIconArt.imageset
cp "$WORK/out/AppIcon-iPad-1024.png" "$ART/AppIconArt.png"
cp "$WORK/out/AppIcon.icns" macOSHost/Resources/AppIcon.icns
if [[ -n "${PREVIEW_DIR:-}" ]]; then
    mkdir -p "$PREVIEW_DIR"
    cp "$WORK/out/MenuBar-preview.png" "$WORK/out/AppIcon-iPad-1024.png" \
        "$WORK/out/AppIcon.iconset/icon_512x512@2x.png" "$PREVIEW_DIR/"
fi
