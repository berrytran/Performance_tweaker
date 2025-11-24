#!/usr/bin/env bash
cpu=$(lscpu | awk -F: '/Model name/ {print $2}' | sed 's/^ *//')
echo "$cpu"
