#!/bin/zsh
# Measures the running app's own CPU use and memory footprint with the menu closed, without showing anything.
# Usage: scripts/idle.sh [seconds=60]. Target: CPU < 2 % (without a timer ~0 %).
set -uo pipefail
N=${1:-60}
P=$(pgrep -x CoffeeControl) || { print "Idle: Coffee Control is not running ❌"; exit 1 }
sec() { ps -o time= -p $P | LC_ALL=C awk -F: '{print $1*60+$2}'; }
/bin/sleep 5   # skip the startup phase
a=$(sec); /bin/sleep $N; b=$(sec)
cpu=$(LC_ALL=C awk -v a=$a -v b=$b -v n=$N 'BEGIN{printf "%.2f", (b-a)/n*100}')
mem=$(footprint $P 2>/dev/null | grep -oE 'Footprint: [0-9.]+ [KMG]B' | head -1)
LC_ALL=C awk -v c=$cpu 'BEGIN{exit !(c<2)}' && z=✅ || z="⚠️ above 2 % – check timers/animations"
print "Idle ${N} s: CPU ${cpu} % $z · ${mem:-footprint ?}"
