#!/bin/zsh
# Regenerates the app icon from scripts/make-app-icon.swift.
#
# The icon is drawn in code rather than kept as ten opaque PNGs, so it can be
# reviewed, diffed, and adjusted like the rest of the interface.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="Sources/Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
swiftc -O scripts/make-app-icon.swift -o "$TMP/make-app-icon"
"$TMP/make-app-icon" "$OUT"
rm -rf "$TMP"
echo "Icon regenerated into $OUT"
