#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then echo "Usage: $0 <percent>"; exit 1; fi
if command -v tlp >/dev/null 2>&1; then sudo tlp setcharge 80 "$PCT" >/dev/null 2>&1 && echo "OK" && exit 0; fi
found=0
for bat in /sys/class/power_supply/*; do
  for file in "charge_control_end_threshold" "charge_control_limit" "charge_control_end_percent"; do
    path="$bat/$file"
    if [ -f "$path" ]; then sudo sh -c "echo $PCT > $path" >/dev/null 2>&1 && found=1 && break 2; fi
  done
done
if [ $found -eq 1 ]; then echo "OK" && exit 0; fi
echo "UNSUPPORTED"; exit 2
