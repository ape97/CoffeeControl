#!/bin/zsh
# Checks Coffee Control (scripts/check.sh), installs it to /Applications and relaunches it.
# Installs only if the checks are green. Afterwards prints status and an idle measurement as proof.
set -euo pipefail
cd "${0:A:h}/.."

./scripts/check.sh || { print "Not installed: checks failed."; exit 1 }

TARGET="/Applications/CoffeeControl.app"
pkill -x CoffeeControl 2>/dev/null && sleep 0.5 || true
rm -rf "$TARGET"
ditto build/Build/Products/Release/CoffeeControl.app "$TARGET"
open -g "$TARGET"
sleep 2
print "\nCoffee Control installed: $TARGET"
./scripts/status.sh
./scripts/idle.sh 60
