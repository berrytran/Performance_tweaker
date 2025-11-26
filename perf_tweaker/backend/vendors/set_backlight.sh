#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then
  echo "Usage: $0 <percent>"
  exit 1
fi
if command -v brightnessctl >/dev/null 2>&1; then
  sudo brightnessctl set "$PCT"% && echo "OK" && exit 0
fi
for b in /sys/class/leds/*kbd_backlight*/brightness /sys/class/leds/*::kbd_backlight/brightness; do
  if [ -f "$b" ]; then
    maxf="$(dirname "$b")/max_brightness"
    if [ -f "$maxf" ]; then
      max=$(cat "$maxf")
      val=$(( PCT * max / 100 ))
      sudo sh -c "echo $val > $b" && echo "OK" && exit 0
    fi
  fi
done
echo "UNSUPPORTED"
exit 2
