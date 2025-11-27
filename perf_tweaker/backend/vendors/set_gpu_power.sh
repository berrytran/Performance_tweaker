#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then echo "Usage: $0 <percent>"; exit 1; fi
if command -v nvidia-settings >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
  sudo nvidia-settings -a "[gpu:0]/GPUFanControlState=1" || true
  sudo nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=$PCT" || true
  echo "OK"; exit 0
fi
if command -v rocm-smi >/dev/null 2>&1; then
  sudo rocm-smi --setfans "$PCT" >/dev/null 2>&1 && echo "OK" && exit 0
fi
echo "UNSUPPORTED"; exit 2
