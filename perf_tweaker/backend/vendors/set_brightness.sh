#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then echo "Usage: $0 <percent>"; exit 1; fi
if command -v brightnessctl >/dev/null 2>&1; then sudo brightnessctl set "$PCT"% && echo "OK" && exit 0; fi
for bdir in /sys/class/backlight/*; do
  if [ -d "$bdir" ]; then
    maxf="$bdir/max_brightness"; brightf="$bdir/brightness"
    if [ -f "$maxf" ] && [ -f "$brightf" ]; then max=$(cat "$maxf"); val=$(( PCT * max / 100 )); sudo sh -c "echo $val > $brightf" && echo "OK" && exit 0; fi
  fi
done
echo "UNSUPPORTED"; exit 2
