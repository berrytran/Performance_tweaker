#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
MODE="system"
if [ "${1-}" = "--user" ]; then MODE="user"; fi
PM=""
if command -v pacman >/dev/null 2>&1; then PM="pacman"
elif command -v apt >/dev/null 2>&1; then PM="apt"
elif command -v dnf >/dev/null 2>&1; then PM="dnf"
elif command -v zypper >/dev/null 2>&1; then PM="zypper"; fi
if [ "$MODE" = "system" ] && [ "$(id -u)" -ne 0 ]; then echo "Run with sudo for system install"; exit 1; fi
if [ "$MODE" = "system" ]; then TARGET_DIR="/opt/perf_tweaker"; BIN_PATH="/usr/bin/perf-tweaker"; DESKTOP_DIR="/usr/share/applications"; ICON_TARGET_DIR="/usr/share/icons/hicolor/256x256/apps"
else TARGET_DIR="$HOME/.local/share/perf_tweaker"; BIN_PATH="$HOME/.local/bin/perf-tweaker"; DESKTOP_DIR="$HOME/.local/share/applications"; ICON_TARGET_DIR="$HOME/.local/share/icons"; mkdir -p "$HOME/.local/bin"; fi
mkdir -p "$TARGET_DIR"
rsync -a --delete --exclude=".git" "$ROOT/" "$TARGET_DIR/"
VENV_DIR="$TARGET_DIR/.venv"
PYBIN="$(command -v python3 || true)"
if [ -z "$PYBIN" ]; then echo "python3 not found"; exit 1; fi
"$PYBIN" -m venv "$VENV_DIR"
. "$VENV_DIR/bin/activate"
pip install -U pip setuptools wheel || true
pip install PyQt5 psutil pygobject || true
deactivate
if [ "$MODE" = "system" ]; then
  cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
TARGET="/opt/perf_tweaker"
VENV="$TARGET/.venv"
export PATH="$VENV/bin:$PATH"
exec "$VENV/bin/python" "$TARGET/run.py" "$@"
EOF
  chmod +x "$BIN_PATH"
else
  cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
TARGET="$HOME/.local/share/perf_tweaker"
VENV="$TARGET/.venv"
export PATH="$VENV/bin:$PATH"
exec "$VENV/bin/python" "$TARGET/run.py" "$@"
EOF
  chmod +x "$BIN_PATH"
fi
mkdir -p "$DESKTOP_DIR"
ICON_SRC=""
if [ -d "$TARGET_DIR/perf_tweaker/icons" ]; then ICON_SRC="$(ls "$TARGET_DIR/perf_tweaker/icons" 2>/dev/null | head -n1 || true)"; if [ -n "$ICON_SRC" ]; then ICON_SRC="$TARGET_DIR/perf_tweaker/icons/$ICON_SRC"; fi; fi
if [ -z "$ICON_SRC" ] || [ ! -f "$ICON_SRC" ]; then ICON_SRC="$TARGET_DIR/perf_tweaker/icons/perf-tweaker.png"; mkdir -p "$(dirname "$ICON_SRC")"; touch "$ICON_SRC"; fi
mkdir -p "$ICON_TARGET_DIR"
cp -f "$ICON_SRC" "$ICON_TARGET_DIR/perf-tweaker.png" 2>/dev/null || cp -f "$ICON_SRC" "$TARGET_DIR/perf-tweaker.png"
ICON_PATH="$( [ -f "$ICON_TARGET_DIR/perf-tweaker.png" ] && echo "$ICON_TARGET_DIR/perf-tweaker.png" || echo "$TARGET_DIR/perf-tweaker.png" )"
DESKTOP_FULL_PATH="$DESKTOP_DIR/perf-tweaker.desktop"
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
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true; fi
echo "Installed to $TARGET_DIR"
