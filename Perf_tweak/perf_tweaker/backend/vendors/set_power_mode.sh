#!/usr/bin/env bash
MODE="$1"
if [ -z "$MODE" ]; then
  echo "Usage: $0 <performance|balanced|power-saver>"
  exit 1
fi
pp="/sys/firmware/acpi/platform_profile"
if [ -w "$pp" ]; then
  echo "$MODE" | sudo tee "$pp" >/dev/null 2>&1 && echo "OK" && exit 0
fi
if command -v powerprofilesctl >/dev/null 2>&1; then
  sudo powerprofilesctl set "$MODE" && echo "OK" && exit 0
fi
echo "UNSUPPORTED"
exit 2
