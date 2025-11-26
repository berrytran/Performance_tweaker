Tired of using multiple backends just to manage gpu mode n power? worry no more with this new all in one ui-based application that managed everything

totally open souce, zero malware
inspired from many Windows performance/power managers

CLI(for sudo)+UI based

# INSTALLATION

1) Install system dependencies (system-wide):
   ```sudo ./install.sh```

   Or for a single-user install:
   ```./install.sh --user```

2) Run the app:
   ```perf-tweaker```
   or
   ```python3 run.py```

3) Build AppImage (optional):
   ./build_appimage.sh
   - This downloads appimagetool and creates PerfTweaker-x86_64.AppImage in this folder.

Notes and caveats:
- Vendor GPU drivers (NVIDIA/ROCm) usually require vendor repos and manual steps; installer installs common helper packages but can't add vendor repos automatically in all cases.
- Some features require kernel support (/sys entries, hwmon). Run 'sudo sensors-detect' and reboot if needed.
- If powerprofilesctl reports missing 'gi', ensure python3-gi / gir packages are installed (installer attempts to do that).
