#!/usr/bin/env bash
info=$("$(dirname "$0")/../backend/detect/all.sh")
cpu=$(echo "$info" | grep CPU | cut -d= -f2)
gpu=$(echo "$info" | grep GPU | cut -d= -f2)

case "$gpu" in
    NVIDIA|Nvidia|nVidia)
        sh "$(dirname "$0")/../backend/vendors/nvidia.sh"
        ;;
    AMD|Advanced)
        sh "$(dirname "$0")/../backend/vendors/amd.sh"
        ;;
    Intel|intel)
        sh "$(dirname "$0")/../backend/vendors/intel.sh"
        ;;
    *)
        echo "Unknown GPU Vendor: $gpu"
        ;;
esac

sudo pacman -S --needed --noconfirm switcheroo-control
