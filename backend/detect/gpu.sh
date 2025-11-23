#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
vendor="unknown"
if command -v lspci >/dev/null 2>&1; then
  gpu3d=$(lspci | grep -Ei '3d controller' | head -n1 | awk -F': ' '{print $3}')
  if [ -n "$gpu3d" ]; then
    vendor="$gpu3d"
  else
    vga=$(lspci | grep -Ei 'vga' | head -n1 | awk -F': ' '{print $3}')
    if [ -n "$vga" ]; then
      vendor="$vga"
    fi
  fi
fi
echo "GPU_VENDOR=$vendor"
