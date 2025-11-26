#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
APPDIR="$ROOT/PerfTweaker.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
cp -r "$ROOT/perf_tweaker" "$APPDIR/"
cp "$ROOT/run.py" "$APPDIR/"
mkdir -p "$APPDIR/icons"
cp -r "$ROOT/perf_tweaker/icons/"* "$APPDIR/icons/" 2>/dev/null || true

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
export PYTHONPATH="$HERE"
exec python3 "$HERE/run.py"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/perf-tweaker.desktop" <<'EOF'
[Desktop Entry]
Name=Perf Tweaker
Exec=AppRun
Icon=perf-tweaker
Type=Application
Categories=Utility;System;
StartupNotify=true
EOF

APPIMAGETOOL="./appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
  wget -q -O "$APPIMAGETOOL" "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod +x "$APPIMAGETOOL"
fi

./appimagetool-x86_64.AppImage "$APPDIR"
echo "AppImage created in $(pwd)"
