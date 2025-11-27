#!/usr/bin/env bash
WATTS="$1"
if [ -z "$WATTS" ]; then echo "Usage: $0 <watts>"; exit 1; fi
written=0
for root in /sys/class/powercap/*; do
  for f in "$root"/*power_limit_uw "$root"/*_power_limit_uw; do
    if [ -f "$f" ]; then
      micro=$(( WATTS * 1000000 ))
      if [ -w "$f" ]; then echo "$micro" > "$f" && written=1 && break 2
      else sudo sh -c "echo $micro > $f" 2>/dev/null && written=1 && break 2; fi
    fi
  done
done
if [ $written -eq 0 ] && command -v ryzenadj >/dev/null 2>&1; then sudo ryzenadj --stapm-limit="$WATTS" >/dev/null 2>&1 && written=1; fi
if [ $written -eq 1 ]; then echo "OK"; exit 0; fi
echo "UNSUPPORTED"; exit 2
