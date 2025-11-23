#!/usr/bin/env bash
if [ -f /sys/devices/virtual/dmi/id/sys_vendor ]; then
  echo "SYS_VENDOR=$(cat /sys/devices/virtual/dmi/id/sys_vendor)"
else
  echo "SYS_VENDOR=unknown"
fi
