#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
"$DIR/cpu.sh"
"$DIR/gpu.sh"
"$DIR/system.sh"
