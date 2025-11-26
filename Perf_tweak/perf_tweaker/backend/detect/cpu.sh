#!/usr/bin/env bash
if command -v lscpu >/dev/null 2>&1; then
  lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print "CPU_VENDOR="$2; exit}'
else
  grep -m1 -i 'model name' /proc/cpuinfo | awk -F': ' '{print "CPU_VENDOR="$2}'
fi
