#!/usr/bin/env bash
HZ="$1"
if [ -z "$HZ" ]; then
  echo "Usage: $0 <hz>"
  exit 1
fi
if ! command -v xrandr >/dev/null 2>&1; then
  echo "UNSUPPORTED"
  exit 2
fi
OUT="$(xrandr --current | awk '/ connected/{print $1; exit}')"
if [ -z "$OUT" ]; then
  echo "UNSUPPORTED"
  exit 2
fi
xrandr --output "$OUT" --rate "$HZ" >/dev/null 2>&1 && echo "OK" && exit 0
MODE="$(xrandr | awk -v out="$OUT" -v hz="$HZ" '
  $0 ~ ("^" out " ") {flag=1; next}
  flag && $0 ~ /^[ \t]+[0-9]/ {
    for(i=1;i<=NF;i++) if($i ~ hz) {print $1; exit}
  }
')"
if [ -n "$MODE" ]; then
  xrandr --output "$OUT" --mode "$MODE" --rate "$HZ" >/dev/null 2>&1 && echo "OK" && exit 0
fi
echo "UNSUPPORTED"
exit 2
