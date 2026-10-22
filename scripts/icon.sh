#!/bin/zsh
# Generates the app icon in all sizes from scripts/icon.swift (SF Symbol on a gradient squircle).
# Usage: scripts/icon.sh <sf-symbol> <top-hex> <bottom-hex>   e.g. scripts/icon.sh doc.on.clipboard 5AC8FA 1D4ED8
set -euo pipefail
cd "${0:A:h}/.."
SET=CoffeeControl/Resources/Assets.xcassets/AppIcon.appiconset
tmp=$(mktemp -d)
swift scripts/icon.swift "$tmp/icon.png" "$1" "$2" "$3"
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$SET/icon_${s}x${s}@1x.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$tmp/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
rm -rf "$tmp"
print "Icon generated ($SET)"
