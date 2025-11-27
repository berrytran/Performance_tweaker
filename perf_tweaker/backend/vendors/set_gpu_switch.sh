#!/usr/bin/env bash
choice="$1"
if [ -z "$choice" ]; then echo "Usage: $0 <auto|nvidia|intel|hybrid|off>"; exit 1; fi
if command -v prime-select >/dev/null 2>&1; then
  case "$choice" in
    nvidia) sudo prime-select nvidia && echo "OK" && exit 0;;
    intel) sudo prime-select intel && echo "OK" && exit 0;;
    hybrid|on-demand) sudo prime-select on-demand && echo "OK" && exit 0;;
    auto) echo "OK" && exit 0;;
  esac
fi
if command -v optimus-manager >/dev/null 2>&1; then
  case "$choice" in
    nvidia) sudo optimus-manager --switch nvidia && echo "OK" && exit 0;;
    intel) sudo optimus-manager --switch intel && echo "OK" && exit 0;;
    hybrid) sudo optimus-manager --switch hybrid && echo "OK" && exit 0;;
    auto) echo "OK" && exit 0;;
  esac
fi
if command -v switcherooctl >/dev/null 2>&1; then echo "switcherooctl present; manual switching may be required" && exit 0; fi
echo "UNSUPPORTED"; exit 2
