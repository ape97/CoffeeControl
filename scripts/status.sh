#!/bin/zsh
# Shows whether Coffee Control is installed correctly and which platform versions are running now.
# Compares against the last tested state in docs/PLATFORM.md. Changes nothing.
set -uo pipefail
cd "${0:A:h}/.."
TARGET=/Applications/CoffeeControl.app
want=$(grep -E 'MARKETING_VERSION' project.yml | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
have=$(defaults read $TARGET/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || print "missing")
print "Version project $want · installed $have $([[ $want == $have ]] && print ✅ || print '❌ → ./scripts/deploy.sh')"
pgrep -qf "$TARGET/Contents/MacOS/CoffeeControl" && print "Running ✅" || print "Not running ❌ → open $TARGET"
codesign --verify --strict $TARGET 2>/dev/null && print "Signature valid ✅" || print "Signature invalid ❌"
# Login item: entry enabled AND pointing at the installed app (not at the build folder).
sfltool dumpbtm 2>/dev/null | python3 -c '
import re, sys
s = re.sub(r"\s+", " ", sys.stdin.read())
m = re.findall(r"Disposition: \[(\w+)[^]]*\] \(\w+\) Identifier: 2\.io\.github\.ape97\.coffeecontrol URL: (\S+)", s)
if not m: print("Login item not found ⚠️ (Settings → Open at Login)")
elif all(d == "enabled" and u == "/Applications/CoffeeControl.app" for d, u in m): print("Login item active ✅")
else: print("Login item wrong ⚠️", m)
'
expiry=$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
print "Signing certificate valid until: ${expiry:-not found} (renew it in Xcode afterwards, then deploy)"

now="macOS=$(sw_vers -productVersion) ($(sw_vers -buildVersion)) Xcode=$(xcodebuild -version | head -1 | awk '{print $2}') SDK=$(xcrun --show-sdk-version)"
last=$(grep -E '^tested:' docs/PLATFORM.md | tail -1 | sed 's/^tested: //; s/ date=.*//')
print "Platform now:    $now"
print "Last tested:     $last"
[[ $now == $last ]] && print "Platform unchanged ✅" || print "Platform changed ⚠️ → re-run scripts/check.sh and review docs/PLATFORM.md"
