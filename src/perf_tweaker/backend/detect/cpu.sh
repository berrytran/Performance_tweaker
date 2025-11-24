#!/usr/bin/env bash
cpu="unknown"
if command -v lscpu >/dev/null 2>&1; then
  cpu_model=$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
  if [ -n "$cpu_model" ]; then
    cpu="$cpu_model"
  fi
else
  cpu_model=$(grep -m1 -i 'model name' /proc/cpuinfo | awk -F': ' '{print $2}')
  if [ -n "$cpu_model" ]; then
    cpu="$cpu_model"
  fi
fi
echo "CPU_VENDOR=$cpu"
