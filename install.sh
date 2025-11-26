#!/usr/bin/env bash
set -euo pipefail

MODE="system"
if [ "${1-}" = "--user" ]; then
  MODE="user"
fi

REPO_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
PKG_MANAGER=""
if command -v pacman >/dev/null 2>&1; then
  PKG_MANAGER="pacman"
elif command -v apt >/dev/null 2>&1; then
  PKG_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
elif command -v zypper >/dev/null 2>&1; then
  PKG_MANAGER="zypper"
fi

if [ "$MODE" = "system" ] && [ "$(id -u)" -ne 0 ]; then
  echo "System install requires sudo. Re-run with sudo:"
  echo "  sudo $0"
  exit 1
fi

if [ "$MODE" = "system" ]; then
  TARGET_DIR="/opt/perf_tweaker"
  BIN_PATH="/usr/bin/perf-tweaker"
  DESKTOP_DIR="/usr/share/applications"
  ICON_TARGET_DIR="/usr/share/icons/hicolor/256x256/apps"
else
  TARGET_DIR="$HOME/.local/share/perf_tweaker"
  BIN_PATH="$HOME/.local/bin/perf-tweaker"
  DESKTOP_DIR="$HOME/.local/share/applications"
  ICON_TARGET_DIR="$HOME/.local/share/icons"
  mkdir -p "$HOME/.local/bin"
fi

mkdir -p "$TARGET_DIR"

if [ "$MODE" = "system" ]; then
  case "$PKG_MANAGER" in
    pacman)
      pacman -Syu --noconfirm
      pacman -S --noconfirm python-gobject gobject-introspection gobject-introspection-runtime \
        lm_sensors cpupower msr-tools ryzenadj nvidia-utils nvidia-settings rocm-smi switcheroo-control \
        optimus-manager brightnessctl tlp acpi xorg-xrandr xorg-xinit xrandr || true
      ;;
    apt)
      apt update -y
      DEBIAN_FRONTEND=noninteractive apt install -y python3-gi gir1.2-gtk-3.0 gir1.2-upowerglib-1.0 \
        gir1.2-polkit-1.0 lm-sensors linux-tools-common msr-tools powertop tlp brightnessctl acpi \
        x11-xserver-utils x11-utils xrandr || true
      ;;
    dnf)
      dnf install -y python3-gobject gobject-introspection lm_sensors cpupower msr-tools powertop \
        tlp brightnessctl acpi xrandr || true
      ;;
    zypper)
      zypper refresh || true
      zypper install -y python3-gobject gobject-introspection lm_sensors cpupower msr-tools \
        tlp brightnessctl acpi xrandr || true
      ;;
    *)
      echo "Unknown package manager. Please install the required system packages manually."
      ;;
  esac
fi

rsync -a --delete --exclude=".git" --exclude="*.AppImage" --exclude="*.pyc" "$REPO_DIR/" "$TARGET_DIR/"

VENV_DIR="$TARGET_DIR/.venv"
PYTHON_BIN="$(command -v python3 || true)"
if [ -z "$PYTHON_BIN" ]; then
  echo "python3 not found. Please install python3 and retry."
  exit 1
fi

"$PYTHON_BIN" -m venv "$VENV_DIR"
. "$VENV_DIR/bin/activate"
pip install --upgrade pip setuptools wheel
pip install PyQt5 psutil pygobject || true
deactivate

if [ "$MODE" = "system" ]; then
  cat > "$BIN_PATH" <<EOF
#!/usr/bin/env bash
TARGET="$TARGET_DIR"
VENV="\$TARGET/.venv"
export PATH="\$VENV/bin:\$PATH"
exec "\$VENV/bin/python" "\$TARGET/run.py" "\$@"
EOF
  chmod +x "$BIN_PATH"
else
  cat > "$BIN_PATH" <<EOF
#!/usr/bin/env bash
TARGET="$TARGET_DIR"
VENV="\$TARGET/.venv"
export PATH="\$VENV/bin:\$PATH"
exec "\$VENV/bin/python" "\$TARGET/run.py" "\$@"
EOF
  chmod +x "$BIN_PATH"
fi

DESKTOP_FILE_NAME="perf-tweaker.desktop"
mkdir -p "$DESKTOP_DIR"
ICON_SRC=""
if [ -d "$TARGET_DIR/perf_tweaker/icons" ]; then
  ICON_SRC="$(ls "$TARGET_DIR/perf_tweaker/icons" 2>/dev/null | head -n1 || true)"
  if [ -n "$ICON_SRC" ]; then
    ICON_SRC="$TARGET_DIR/perf_tweaker/icons/$ICON_SRC"
  fi
fi
if [ -z "$ICON_SRC" ] || [ ! -f "$ICON_SRC" ]; then
  ICON_SRC="$TARGET_DIR/perf_tweaker/icons/perf-tweaker.png"
  mkdir -p "$(dirname "$ICON_SRC")"
  touch "$ICON_SRC"
fi

mkdir -p "$ICON_TARGET_DIR"
cp -f "$ICON_SRC" "$ICON_TARGET_DIR/perf-tweaker.png" 2>/dev/null || cp -f "$ICON_SRC" "$TARGET_DIR/perf-tweaker.png"
ICON_PATH="$( [ -f "$ICON_TARGET_DIR/perf-tweaker.png" ] && echo "$ICON_TARGET_DIR/perf-tweaker.png" || echo "$TARGET_DIR/perf-tweaker.png" )"

DESKTOP_FULL_PATH="$DESKTOP_DIR/$DESKTOP_FILE_NAME"
cat > "$DESKTOP_FULL_PATH" <<EOF
[Desktop Entry]
Name=Perf Tweaker
Comment=Adjust power, fans, brightness and GPU switching
Exec=$BIN_PATH
Icon=$ICON_PATH
Type=Application
Categories=Utility;System;
StartupNotify=true
EOF

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

echo "Installation complete."
echo " - App files: $TARGET_DIR"
echo " - Launcher: $BIN_PATH"
echo " - Desktop file: $DESKTOP_FULL_PATH"
echo " - Icon: $ICON_PATH"
