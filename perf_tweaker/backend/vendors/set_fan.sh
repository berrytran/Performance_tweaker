#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then echo "Usage: $0 <percent>"; exit 1; fi
found=0
for h in /sys/class/hwmon/*; do
  for pwm in "$h"/pwm*; do
    if [ -e "$pwm" ]; then
      maxval=255; val=$(( PCT * maxval / 100 ))
      if [ -w "$pwm" ]; then echo "$val" > "$pwm" && found=1 && break 2
      else sudo sh -c "echo $val > $pwm" 2>/dev/null && found=1 && break 2; fi
    fi
  done
done
if [ $found -eq 1 ]; then echo "OK"; exit 0; fi
echo "UNSUPPORTED"; exit 2
