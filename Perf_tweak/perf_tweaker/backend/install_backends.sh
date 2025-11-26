#!/usr/bin/env bash
set -euo pipefail
echo "Backend installer: will attempt to install required system packages for Perf Tweaker."
echo "This tries to cover common packages across many distributions (best-effort)."
read -p "Proceed with automatic installation? [y/N]: " ans
case "$ans" in
  y|Y) ;;
  *) echo "Aborted by user."; exit 1;;
esac

if command -v pacman >/dev/null 2>&1; then
  PM="pacman"
elif command -v apt >/dev/null 2>&1; then
  PM="apt"
elif command -v dnf >/dev/null 2>&1; then
  PM="dnf"
elif command -v zypper >/dev/null 2>&1; then
  PM="zypper"
else
  PM="unknown"
fi

echo "Detected package manager: $PM"
failed=()

install_pacman(){
  sudo pacman -Syu --noconfirm
  sudo pacman -S --noconfirm python-gobject gobject-introspection gobject-introspection-runtime \
    lm_sensors cpupower msr-tools ryzenadj nvidia-utils nvidia-settings rocm-smi switcheroo-control \
    optimus-manager brightnessctl tlp acpi xorg-xrandr xorg-xrandr xorg-xinit || true
}

install_apt(){
  sudo apt update -y
  sudo apt install -y python3-gi gir1.2-gtk-3.0 gir1.2-upowerglib-1.0 gir1.2-polkit-1.0 \
    lm-sensors linux-tools-common msr-tools powertop tlp brightnessctl acpi x11-xserver-utils x11-utils xrandr || true
  # NVIDIA/ROCm often need vendor repos; note to user
  echo "Note: Nvidia/ROCm packages may require vendor repositories on Debian/Ubuntu."
}

install_dnf(){
  sudo dnf install -y python3-gobject gobject-introspection python3-gobject-base \
    lm_sensors cpupower msr-tools powertop tlp brightnessctl acpi xrandr || true
  echo "Note: install vendor GPU packages (NVIDIA/ROCm) via distro instructions."
}

install_zypper(){
  sudo zypper refresh || true
  sudo zypper install -y python3-gobject gobject-introspection lm_sensors cpupower msr-tools \
    tlp brightnessctl acpi xrandr || true
  echo "Note: install vendor GPU packages (NVIDIA/ROCm) via distro instructions."
}

case "$PM" in
  pacman) install_pacman ;;
  apt) install_apt ;;
  dnf) install_dnf ;;
  zypper) install_zypper ;;
  *)
    echo "Unknown package manager. Please install the following packages manually:"
    echo "  python3-gi, gir1.2-gtk-3.0, gir1.2-upowerglib-1.0, gobject-introspection, lm_sensors, cpupower, msr-tools, ryzenadj, nvidia-utils/nvidia-settings, rocm-smi, switcheroo-control, optimus-manager, brightnessctl, tlp, acpi, xrandr"
    exit 1
    ;;
esac

echo "Post-install recommendations:"
echo "  - Run 'sudo sensors-detect' and reboot if new kernel modules were added."
echo "  - If you rely on NVIDIA or ROCm, ensure vendor repos/driver installation steps were followed."
echo "  - If anything failed, rerun installer and inspect errors."

echo "Done."
