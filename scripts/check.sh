#!/bin/zsh
# Checks Coffee Control completely and invisibly: build (no errors/warnings), snapshots, self-test, performance test.
# Changes nothing on the system, opens no windows. Result: summary + exit code (0 = green).
set -uo pipefail
cd "${0:A:h}/.."
OUT=build/check
rm -rf $OUT; mkdir -p $OUT
failed=0
ok()   { print "✅ $1" }
fail() { print "❌ $1"; failed=1 }

xcodegen generate -q || { fail "xcodegen"; exit 1 }
xcodebuild -project CoffeeControl.xcodeproj -scheme CoffeeControl -configuration Release \
  -derivedDataPath build build > build/log.txt 2>&1
grep -q "BUILD SUCCEEDED" build/log.txt && ok "Build" || { fail "Build (build/log.txt)"; grep -E "error:" build/log.txt | head -20; exit 1 }
warn=$(grep -E "warning:" build/log.txt | grep -v appintents | sort -u)
[[ -z $warn ]] && ok "no warnings" || { fail "Warnings:"; print -- "$warn" | head -30 }

APP="$PWD/build/Build/Products/Release/CoffeeControl.app"
BIN="$APP/Contents/MacOS/CoffeeControl"
# One entry "name:arguments" per view – add new pages/states here.
for v in "main:" "off:--off" "no-rule:--nohelper" "closed:--closed" "settings:--settings" "settings-no-rule:--settings --nohelper --error" "battery-pause:--battery" "settings-battery:--settings --battery" "sleep:--sleep --blocked" "sleep-free:--sleep" "sleep-no-rule:--sleep --nohelper" "timer:--timer 30 --left 24 --then-sleep" "no-timer:--no-timer" "timer-sleep:--sleep --timer 60 --left 42" "times:--timer 960 --left 959 --times 15,90,150,480,960,1440" "settings-times:--settings --times 15,90,150,480,960,1440"; do
  name=${v%%:*}; args=(${=v#*:})
  "$BIN" --snapshot $OUT/$name $args >/dev/null 2>&1
  [[ -s $OUT/$name-light.png && -s $OUT/$name-dark.png ]] || fail "Snapshot $name"
done
ok "Snapshots in $OUT (take a look!)"

# Self-test: app logic, JSON {ok, failures, …}
f=$OUT/selftest.json
open -n -g -a "$APP" --args --selftest $PWD/$f
for i in {1..60}; do [[ -f $f ]] && break; /bin/sleep 1; done
if [[ -f $f ]]; then
  python3 - "$f" <<'PY' && ok "Self-test" || fail "Self-test ($f)"
import json, sys
d = json.load(open(sys.argv[1]))
print("   " + " ".join(f"{k}={v}" for k, v in d.items()))
sys.exit(0 if d.get("ok") is True and not d.get("failures") else 1)
PY
else
  fail "Self-test: no output"
fi

# Performance test: the menu stays structurally quiet on updates (otherwise macOS keeps resetting the pointer).
f=$OUT/structure.json
"$BIN" --structuretest $PWD/$f >/dev/null 2>&1
if [[ -f $f ]]; then
  python3 - "$f" <<'PY' && ok "Performance test" || fail "Performance test ($f)"
import json, sys
d = json.load(open(sys.argv[1]))
print(f"   steps={d.get('steps')} structural={d.get('structural')} tracking={d.get('tracking')} failures={d.get('failures')}")
sys.exit(0 if d.get("ok") is True else 1)
PY
else
  fail "Performance test: no output"
fi
(( failed )) && print "\nRESULT: RED" || print "\nRESULT: GREEN"
exit $failed
