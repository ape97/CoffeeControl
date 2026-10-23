#!/bin/zsh
# Renders every menu page with invented demo data and composes the README images into docs/images/.
# Invisible: no windows; nothing is read from or written to your settings.
set -euo pipefail
cd "${0:A:h}/.."
BIN=CoffeeControl
COLORS=(D9B08C 6B452D)   # the icon's gradient colours (top, bottom), see scripts/icon.sh
# page:snapshot arguments (the first page also provides the menu bar icon)
PAGES=("main:" "normal:--off" "sleep:--sleep --blocked" "battery-pause:--battery" "timer:--timer 30 --left 24 --then-sleep" "settings:--settings" "update:--update 1.4.0")
# extra states only for the animations (rendered to RAW, not composed)
EXTRA=("timer-start:--timer 30 --left 30" "timer-then:--timer 30 --left 30 --then-sleep" "timer-late:--timer 30 --left 1 --then-sleep"
       "dur-typed:--settings --draft 8h" "dur-added:--settings --times 15,30,60,120,240,480"
       "dur-main:--times 15,30,60,120,240,480" "dur-run:--timer 480 --left 480 --times 15,30,60,120,240,480")

mkdir -p build
xcodegen generate -q
xcodebuild -project $BIN.xcodeproj -scheme $BIN -configuration Release -derivedDataPath build build > build/screenshots-build.log 2>&1 \
  || { tail -20 build/screenshots-build.log; exit 1 }
RAW=build/screenshots/raw
rm -rf $RAW; mkdir -p $RAW docs/images
for page in $PAGES $EXTRA; do
  build/Build/Products/Release/$BIN.app/Contents/MacOS/$BIN --snapshot $RAW/${page%%:*} ${=page#*:} --demo >/dev/null 2>&1
done
swift scripts/compose.swift $RAW docs/images $COLORS ${PAGES%%:*}
cp CoffeeControl/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png docs/images/icon.png   # README header

# Animations: every scripts/scenes/<name>.json plays over the pages above (see compose.swift --scene); ffmpeg joins the
# frames into docs/images/<name>.gif with one shared palette, writing only the changed area of each frame
# (15 fps and at most 1200 px wide keep a 20-second walkthrough near 2–3 MB).
if command -v ffmpeg >/dev/null; then
  for scene in scripts/scenes/*.json(N); do
    out=build/screenshots/scene-${scene:t:r}
    rm -rf $out; mkdir -p $out
    swift scripts/compose.swift --scene $scene $RAW $out $COLORS
    ffmpeg -v error -y -f concat -i $out/frames.txt \
      -vf "fps=15,scale='min(iw,1200)':-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
      -loop 0 docs/images/${scene:t:r}.gif
    print docs/images/${scene:t:r}.gif
  done
else
  print "ffmpeg not found: animations not updated (brew install ffmpeg)"
fi
