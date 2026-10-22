#!/bin/zsh
# Measures CPU use while the menu is OPEN. Start the script (in the background), then open the menu and use it
# normally (move the mouse over lists). It ends 1 s after the "Menu closed" log line (max. 20 min).
# Writes build/measure/history.txt (CPU seconds per 0.5 s) and, on the first spike, a 30 s sample (sample.txt).
# Evaluation: sum/duration = CPU %; search sample.txt for hot paths (target while open: < 5 %).
set -uo pipefail
cd "${0:A:h}/.."
D=build/measure; mkdir -p $D; : > $D/history.txt; rm -f $D/sample.txt
P=$(pgrep -x CoffeeControl) || { print "Coffee Control is not running"; exit 1 }
sec() { ps -o time= -p $P | LC_ALL=C awk -F: '{print $1*60+$2}'; }
start=$(date '+%Y-%m-%d %H:%M:%S'); prev=$(sec); sampled=0
for i in {1..2400}; do
  /bin/sleep 0.5; c=$(sec)
  LC_ALL=C awk -v t=$(date +%T) -v p=$prev -v c=$c 'BEGIN{printf "%s %6.3f\n",t,(c-p)}' >> $D/history.txt
  if (( !sampled )) && LC_ALL=C awk -v p=$prev -v c=$c 'BEGIN{exit !(c-p>0.03)}'; then
    /usr/bin/sample $P 30 -file $PWD/$D/sample.txt >/dev/null 2>&1 & sampled=1
  fi
  prev=$c
  if (( i % 4 == 0 )) && /usr/bin/log show --start "$start" --predicate 'subsystem == "io.github.ape97.coffeecontrol"' --style compact 2>/dev/null | grep -q "Menu closed"; then
    /bin/sleep 1; break
  fi
done
wait
LC_ALL=C awk '{s+=$2; n++} END{printf "Menu open: %.1f s, CPU %.1f %%\n", n/2, (n?s/(n/2)*100:0)}' $D/history.txt
