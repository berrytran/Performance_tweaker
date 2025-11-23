#!/usr/bin/env bash
set -e

mkdir -p backend/detect backend/vendors ui

cat > backend/detect/cpu.sh <<'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cpu="unknown"
if command -v lscpu >/dev/null 2>&1; then
  cpu_model=$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
  if [ -n "$cpu_model" ]; then
    cpu="$cpu_model"
  fi
else
  cpu_model=$(grep -m1 -i 'model name' /proc/cpuinfo | awk -F': ' '{print $2}')
  if [ -n "$cpu_model" ]; then
    cpu="$cpu_model"
  fi
fi
echo "CPU_VENDOR=$cpu"
EOF

cat > backend/detect/gpu.sh <<'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
vendor="unknown"
if command -v lspci >/dev/null 2>&1; then
  gpu3d=$(lspci | grep -Ei '3d controller' | head -n1 | awk -F': ' '{print $3}')
  if [ -n "$gpu3d" ]; then
    vendor="$gpu3d"
  else
    vga=$(lspci | grep -Ei 'vga' | head -n1 | awk -F': ' '{print $3}')
    if [ -n "$vga" ]; then
      vendor="$vga"
    fi
  fi
fi
echo "GPU_VENDOR=$vendor"
EOF

cat > backend/detect/system.sh <<'EOF'
#!/usr/bin/env bash
if [ -f /sys/devices/virtual/dmi/id/sys_vendor ]; then
  echo "SYS_VENDOR=$(cat /sys/devices/virtual/dmi/id/sys_vendor)"
else
  echo "SYS_VENDOR=unknown"
fi
EOF

cat > backend/detect/all.sh <<'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
"$DIR/cpu.sh"
"$DIR/gpu.sh"
"$DIR/system.sh"
EOF

cat > backend/vendors/set_cpu_power.sh <<'EOF'
#!/usr/bin/env bash
WATTS="$1"
if [ -z "$WATTS" ]; then
  echo "Usage: $0 <watts>"
  exit 1
fi
written=0
for root in /sys/class/powercap/*; do
  for f in "$root"/*power_limit_uw "$root"/*_power_limit_uw; do
    if [ -f "$f" ]; then
      micro=$(( WATTS * 1000000 ))
      if [ -w "$f" ]; then
        echo "$micro" > "$f" && written=1 && break 2
      else
        sudo sh -c "echo $micro > $f" 2>/dev/null && written=1 && break 2
      fi
    fi
  done
done
if [ $written -eq 0 ]; then
  if command -v ryzenadj >/dev/null 2>&1; then
    sudo ryzenadj --stapm-limit="$WATTS" && written=1
  elif command -v cpupower >/dev/null 2>&1; then
    echo "$WATTS" >/dev/null && written=0
  fi
fi
if [ $written -eq 1 ]; then
  echo "OK"
else
  echo "UNSUPPORTED"
  exit 2
fi
EOF

cat > backend/vendors/set_fan.sh <<'EOF'
#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then
  echo "Usage: $0 <percent>"
  exit 1
fi
found=0
for h in /sys/class/hwmon/*; do
  for pwm in "$h"/pwm*; do
    if [ -e "$pwm" ]; then
      maxval=255
      val=$(( PCT * maxval / 100 ))
      if [ -w "$pwm" ]; then
        echo "$val" > "$pwm" && found=1 && break 2
      else
        sudo sh -c "echo $val > $pwm" 2>/dev/null && found=1 && break 2
      fi
    fi
  done
done
if [ $found -eq 1 ]; then
  echo "OK"
else
  echo "UNSUPPORTED"
  exit 2
fi
EOF

cat > backend/vendors/set_gpu_power.sh <<'EOF'
#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then
  echo "Usage: $0 <percent>"
  exit 1
fi
if command -v nvidia-settings >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
  sudo nvidia-settings -a "[gpu:0]/GPUFanControlState=1" || true
  sudo nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=$PCT" || true
  echo "OK" && exit 0
fi
if command -v rocm-smi >/dev/null 2>&1; then
  sudo rocm-smi --setfans "$PCT" 2>/dev/null && echo "OK" && exit 0
fi
echo "UNSUPPORTED"
exit 2
EOF

cat > backend/vendors/set_power_mode.sh <<'EOF'
#!/usr/bin/env bash
MODE="$1"
if [ -z "$MODE" ]; then
  echo "Usage: $0 <performance|balanced|power-saver>"
  exit 1
fi
if command -v powerprofilesctl >/dev/null 2>&1; then
  sudo powerprofilesctl set "$MODE" && echo "OK" && exit 0
fi
echo "UNSUPPORTED"
exit 2
EOF

cat > backend/vendors/set_refresh_rate.sh <<'EOF'
#!/usr/bin/env bash
HZ="$1"
if [ -z "$HZ" ]; then
  echo "Usage: $0 <hz>"
  exit 1
fi
if ! command -v xrandr >/dev/null 2>&1; then
  echo "UNSUPPORTED"
  exit 2
fi
OUT="$(xrandr --current | awk '/ connected/{print $1; exit}')"
if [ -z "$OUT" ]; then
  echo "UNSUPPORTED"
  exit 2
fi
# find matching mode line by refresh rate (best-effort)
MODE_LINE="$(xrandr | awk -v out="$OUT" -v hz="$HZ" '
  $0 ~ ("^" out " ") {flag=1; next}
  flag && $0 ~ /^[ ]+[0-9]/ {
    for(i=1;i<=NF;i++) if($i ~ hz) { print $1; exit }
  }
')"
if [ -n "$MODE_LINE" ]; then
  xrandr --output "$OUT" --mode "$MODE_LINE" --rate "$HZ" && echo "OK" && exit 0
fi
echo "UNSUPPORTED"
exit 2
EOF

cat > backend/vendors/set_backlight.sh <<'EOF'
#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then
  echo "Usage: $0 <percent>"
  exit 1
fi
if command -v brightnessctl >/dev/null 2>&1; then
  sudo brightnessctl set "$PCT"% && echo "OK" && exit 0
fi
for b in /sys/class/leds/*kbd_backlight*/brightness /sys/class/leds/*::kbd_backlight/brightness; do
  if [ -f "$b" ]; then
    maxf="$(dirname "$b")/max_brightness"
    if [ -f "$maxf" ]; then
      max=$(cat "$maxf")
      val=$(( PCT * max / 100 ))
      sudo sh -c "echo $val > $b" && echo "OK" && exit 0
    fi
  fi
done
echo "UNSUPPORTED"
exit 2
EOF

cat > backend/vendors/set_charge_limit.sh <<'EOF'
#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then
  echo "Usage: $0 <percent>"
  exit 1
fi
if command -v tlp >/dev/null 2>&1; then
  sudo tlp setcharge 80 "$PCT" >/dev/null 2>&1 && echo "OK" && exit 0
fi
found=0
for bat in /sys/class/power_supply/*; do
  for file in "charge_control_end_threshold" "charge_control_limit" "charge_control_end_percent"; do
    path="$bat/$file"
    if [ -f "$path" ]; then
      sudo sh -c "echo $PCT > $path" >/dev/null 2>&1 && found=1 && break 2
    fi
  done
done
if [ $found -eq 1 ]; then
  echo "OK" && exit 0
fi
echo "UNSUPPORTED"
exit 2
EOF

cat > backend/vendors/set_brightness.sh <<'EOF'
#!/usr/bin/env bash
PCT="$1"
if [ -z "$PCT" ]; then
  echo "Usage: $0 <percent>"
  exit 1
fi
if command -v brightnessctl >/dev/null 2>&1; then
  sudo brightnessctl set "$PCT"% && echo "OK" && exit 0
fi
for bdir in /sys/class/backlight/*; do
  if [ -d "$bdir" ]; then
    maxf="$bdir/max_brightness"
    brightf="$bdir/brightness"
    if [ -f "$maxf" ] && [ -f "$brightf" ]; then
      max=$(cat "$maxf")
      val=$(( PCT * max / 100 ))
      sudo sh -c "echo $val > $brightf" && echo "OK" && exit 0
    fi
  fi
done
echo "UNSUPPORTED"
exit 2
EOF

cat > ui/main.py <<'PY'
#!/usr/bin/env python3
import sys
import os
import shutil
import glob
import subprocess
import psutil
from PyQt5.QtWidgets import QApplication, QWidget, QLabel, QVBoxLayout, QSlider, QTabWidget, QMessageBox, QPushButton, QComboBox, QHBoxLayout
from PyQt5.QtCore import Qt, QTimer

def run_command(cmd, timeout=2):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, timeout=timeout).strip()
    except Exception:
        return ""

def request_sudo(parent=None):
    try:
        p = subprocess.run(["sudo", "-v"])
        if p.returncode == 0:
            return True
    except Exception:
        pass
    if parent is None:
        return False
    dlg = QMessageBox(parent)
    dlg.setWindowTitle("Sudo required")
    dlg.setText("This app can control hardware and may need sudo for some actions.\nEnter your password in the terminal if you want full control.\nContinue without sudo will disable controls that require root.")
    retry = dlg.addButton("Retry (enter password)", QMessageBox.AcceptRole)
    cont = dlg.addButton("Continue without sudo", QMessageBox.RejectRole)
    dlg.exec_()
    if dlg.clickedButton() == retry:
        try:
            p = subprocess.run(["sudo", "-v"])
            return p.returncode == 0
        except Exception:
            return False
    return False

def read_int_file(path):
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return None

def find_powercap_current_max():
    base = "/sys/class/powercap"
    if not os.path.isdir(base):
        return (None, None)
    for root, dirs, files in os.walk(base):
        cur = None
        mx = None
        for name in files:
            if name.endswith("_power_limit_uw") or name.endswith("power_limit_uw") or name == "power_uw":
                val = read_int_file(os.path.join(root, name))
                if val is not None:
                    cur = val / 1_000_000.0
            if name.endswith("_max_power_uw") or name.endswith("max_power_uw"):
                val = read_int_file(os.path.join(root, name))
                if val is not None:
                    mx = val / 1_000_000.0
        if cur is not None or mx is not None:
            return (cur, mx)
    return (None, None)

def find_writable_hwmon_pwm():
    hwmon_dir = "/sys/class/hwmon"
    if not os.path.isdir(hwmon_dir):
        return None
    for h in sorted(os.listdir(hwmon_dir)):
        path = os.path.join(hwmon_dir, h)
        for pwm in sorted(glob.glob(os.path.join(path, "pwm*"))):
            try:
                if os.path.exists(pwm) and os.access(pwm, os.W_OK):
                    return pwm
            except Exception:
                continue
    return None

def has_dedicated_gpu():
    out = run_command("lspci -nn")
    if not out:
        return False
    for line in out.splitlines():
        if "3D controller" in line or "3D Controller" in line:
            return True
    for line in out.splitlines():
        if "VGA compatible controller" in line or "VGA" in line:
            low = line.lower()
            if ("nvidia" in low) or ("amd" in low) or ("advanced micro devices" in low) or ("radeon" in low) or ("ati " in low):
                return True
    return False

def nvidia_fan_control_available():
    if not shutil.which("nvidia-settings"):
        return False
    display = os.environ.get("DISPLAY")
    if not display:
        return False
    try:
        p = subprocess.run(
            ["nvidia-settings", "-q", "[gpu:0]/GPUFanControlState"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2,
            env={**os.environ, "DISPLAY": display}
        )
        return p.returncode == 0
    except Exception:
        return False

def rocm_fan_control_available():
    if not shutil.which("rocm-smi"):
        return False
    out = run_command("rocm-smi --showfan 2>/dev/null")
    return bool(out)

def gpu_fan_available():
    if not has_dedicated_gpu():
        return False
    if nvidia_fan_control_available():
        return True
    if rocm_fan_control_available():
        return True
    if os.path.isfile("./backend/vendors/set_gpu_power.sh"):
        return True
    return False

def cpu_power_available():
    cur, mx = find_powercap_current_max()
    if mx is not None:
        return True
    if os.path.isfile("./backend/vendors/set_cpu_power.sh"):
        return True
    return False

class CpuTab(QWidget):
    def __init__(self, sudo_ok):
        super().__init__()
        self.sudo_ok = bool(sudo_ok)
        self.cpu_power_max = None
        self.cpu_power_cur = None
        self.init_ui()
        self.update_availability()
        self.start_timer()

    def init_ui(self):
        layout = QVBoxLayout()
        self.vendor_label = QLabel("CPU: Detecting...")
        layout.addWidget(self.vendor_label)
        self.temp_label = QLabel("Temp: --")
        self.freq_label = QLabel("Freq: --")
        layout.addWidget(self.temp_label)
        layout.addWidget(self.freq_label)
        cur, mx = find_powercap_current_max()
        self.cpu_power_cur = cur
        self.cpu_power_max = int(mx) if mx is not None else None
        if self.cpu_power_max is not None:
            initial = int(self.cpu_power_cur) if self.cpu_power_cur is not None else (self.cpu_power_max // 2)
            label_text = f"CPU Power: {initial} W / {self.cpu_power_max} W"
        else:
            initial = 1
            label_text = "CPU Power: not adjustable"
        self.cpu_power_label = QLabel(label_text)
        self.cpu_power_slider = QSlider(Qt.Horizontal)
        self.cpu_power_slider.setMinimum(1)
        if self.cpu_power_max is not None:
            self.cpu_power_slider.setMaximum(self.cpu_power_max)
            self.cpu_power_slider.setValue(initial)
        else:
            self.cpu_power_slider.setMaximum(1)
            self.cpu_power_slider.setValue(1)
        self.cpu_power_slider.valueChanged.connect(self.on_power_change)
        layout.addWidget(self.cpu_power_label)
        layout.addWidget(self.cpu_power_slider)
        self.cpu_fan_label = QLabel("CPU Fan: --")
        self.cpu_fan_slider = QSlider(Qt.Horizontal)
        self.cpu_fan_slider.setMinimum(0)
        self.cpu_fan_slider.setMaximum(100)
        self.cpu_fan_slider.setValue(50)
        self.cpu_fan_slider.valueChanged.connect(self.on_fan_change)
        layout.addWidget(self.cpu_fan_label)
        layout.addWidget(self.cpu_fan_slider)
        self.setLayout(layout)

    def start_timer(self):
        self.timer = QTimer()
        self.timer.timeout.connect(self.update_live)
        self.timer.start(2000)
        self.refresh_detection()

    def refresh_detection(self):
        out = run_command("./backend/detect/all.sh")
        for line in out.splitlines():
            if line.startswith("CPU_VENDOR="):
                self.vendor_label.setText(f"CPU: {line.split('=',1)[1].strip()}")

    def update_live(self):
        cpu_temp = run_command("sensors | awk -F: '/Package id 0|Core 0|Tdie|Tctl/ {print $2; exit}'").strip()
        self.temp_label.setText(f"Temp: {cpu_temp}" if cpu_temp else "Temp: --")
        try:
            freq = psutil.cpu_freq().current
            self.freq_label.setText(f"Freq: {freq:.0f} MHz" if freq else "Freq: --")
        except Exception:
            self.freq_label.setText("Freq: --")
        cur, mx = find_powercap_current_max()
        self.cpu_power_cur = cur
        if mx is not None:
            self.cpu_power_max = int(mx)
            self.cpu_power_slider.setMaximum(self.cpu_power_max)
        if self.cpu_power_max is not None:
            cur_display = int(self.cpu_power_cur) if self.cpu_power_cur is not None else self.cpu_power_slider.value()
            self.cpu_power_label.setText(f"CPU Power: {cur_display} W / {self.cpu_power_max} W")
        else:
            self.cpu_power_label.setText("CPU Power: not adjustable")
        pwm = find_writable_hwmon_pwm()
        if pwm:
            self.cpu_fan_label.setText(f"CPU Fan: settable via {os.path.basename(pwm)}")
        else:
            self.cpu_fan_label.setText("CPU Fan: not adjustable")

    def update_availability(self):
        power_ok = cpu_power_available() and self.sudo_ok
        fan_ok = (find_writable_hwmon_pwm() is not None) and self.sudo_ok
        self.cpu_power_slider.setEnabled(bool(power_ok))
        self.cpu_fan_slider.setEnabled(bool(fan_ok))

    def on_power_change(self, v):
        if self.cpu_power_max is None or not self.cpu_power_slider.isEnabled():
            return
        self.cpu_power_label.setText(f"CPU Power: {v} W / {self.cpu_power_max} W")
        try:
            subprocess.Popen(["sudo", "bash", "./backend/vendors/set_cpu_power.sh", str(v)])
        except Exception:
            pass

    def on_fan_change(self, v):
        self.cpu_fan_label.setText(f"CPU Fan: {v} %")
        if not self.cpu_fan_slider.isEnabled():
            return
        pwm = find_writable_hwmon_pwm()
        if pwm:
            try:
                val = int(v * 255 / 100)
                subprocess.Popen(["sudo", "sh", "-c", f"echo {val} > {pwm}"])
                return
            except Exception:
                pass
        try:
            subprocess.Popen(["sudo", "bash", "./backend/vendors/set_fan.sh", str(v)])
        except Exception:
            pass

class GpuTab(QWidget):
    def __init__(self, sudo_ok):
        super().__init__()
        self.sudo_ok = bool(sudo_ok)
        self.init_ui()
        self.update_availability()
        self.start_timer()

    def init_ui(self):
        layout = QVBoxLayout()
        self.vendor_label = QLabel("GPU: Detecting...")
        layout.addWidget(self.vendor_label)
        self.temp_label = QLabel("Temp: --")
        self.util_label = QLabel("Util: --")
        layout.addWidget(self.temp_label)
        layout.addWidget(self.util_label)
        self.gpu_power_label = QLabel("GPU Power (custom %): --")
        self.gpu_power_slider = QSlider(Qt.Horizontal)
        self.gpu_power_slider.setMinimum(0)
        self.gpu_power_slider.setMaximum(100)
        self.gpu_power_slider.setValue(50)
        self.gpu_power_slider.valueChanged.connect(self.on_power_change)
        layout.addWidget(self.gpu_power_label)
        layout.addWidget(self.gpu_power_slider)
        self.gpu_fan_label = QLabel("GPU Fan: --")
        self.gpu_fan_slider = QSlider(Qt.Horizontal)
        self.gpu_fan_slider.setMinimum(0)
        self.gpu_fan_slider.setMaximum(100)
        self.gpu_fan_slider.setValue(50)
        self.gpu_fan_slider.valueChanged.connect(self.on_fan_change)
        layout.addWidget(self.gpu_fan_label)
        layout.addWidget(self.gpu_fan_slider)
        self.setLayout(layout)

    def start_timer(self):
        self.timer = QTimer()
        self.timer.timeout.connect(self.update_live)
        self.timer.start(2000)
        self.refresh_detection()

    def refresh_detection(self):
        out = run_command("./backend/detect/all.sh")
        for line in out.splitlines():
            if line.startswith("GPU_VENDOR="):
                self.vendor_label.setText(f"GPU: {line.split('=',1)[1].strip()}")

    def update_live(self):
        if shutil.which("nvidia-smi"):
            gtemp = run_command("nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null").strip()
            util = run_command("nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null").strip()
            if gtemp:
                self.temp_label.setText(f"Temp: {gtemp} °C")
            if util:
                self.util_label.setText(f"Util: {util}")
        elif shutil.which("rocm-smi"):
            gtemp = run_command("rocm-smi --showtemp 2>/dev/null").strip()
            if gtemp:
                self.temp_label.setText(f"Temp: {gtemp}")
        else:
            self.temp_label.setText("Temp: --")
            self.util_label.setText("Util: --")
        if has_dedicated_gpu():
            self.gpu_fan_label.setText("GPU Fan: available" if gpu_fan_available() else "GPU Fan: control method missing")
            self.gpu_power_label.setText("GPU Power (custom %): available" if gpu_fan_available() else "GPU Power: control method missing")
        else:
            self.gpu_fan_label.setText("GPU Fan: not applicable (iGPU only)")
            self.gpu_power_label.setText("GPU Power: not applicable (iGPU only)")

    def update_availability(self):
        power_ok = gpu_fan_available() and self.sudo_ok
        fan_ok = gpu_fan_available() and self.sudo_ok
        self.gpu_power_slider.setEnabled(bool(power_ok))
        self.gpu_fan_slider.setEnabled(bool(fan_ok))

    def on_power_change(self, v):
        if not self.gpu_power_slider.isEnabled():
            return
        self.gpu_power_label.setText(f"GPU Power (custom %): {v} %")
        try:
            subprocess.Popen(["sudo", "bash", "./backend/vendors/set_gpu_power.sh", str(v)])
        except Exception:
            pass

    def on_fan_change(self, v):
        if not self.gpu_fan_slider.isEnabled():
            return
        self.gpu_fan_label.setText(f"GPU Fan: {v} %")
        if shutil.which("nvidia-settings") and os.environ.get("DISPLAY"):
            try:
                display = os.environ.get("DISPLAY")
                subprocess.Popen(["sudo", "nvidia-settings", "-a", "[gpu:0]/GPUFanControlState=1"], env={**os.environ, "DISPLAY": display})
                subprocess.Popen(["sudo", "nvidia-settings", "-a", f"[fan:0]/GPUTargetFanSpeed={v}"], env={**os.environ, "DISPLAY": display})
                return
            except Exception:
                pass
        if shutil.which("rocm-smi"):
            try:
                subprocess.Popen(["sudo", "rocm-smi", "--setfans", str(v)])
                return
            except Exception:
                pass
        try:
            subprocess.Popen(["sudo", "bash", "./backend/vendors/set_gpu_power.sh", str(v)])
        except Exception:
            pass

class GeneralTab(QWidget):
    def __init__(self, sudo_ok):
        super().__init__()
        self.sudo_ok = bool(sudo_ok)
        self.init_ui()
        self.update_availability()

    def init_ui(self):
        layout = QVBoxLayout()
        self.power_mode_label = QLabel("Power Mode: Unknown")
        self.power_mode_combo = QComboBox()
        self.power_mode_combo.addItems(["performance","balanced","power-saver"])
        self.power_mode_combo.currentIndexChanged.connect(self.set_power_mode)
        layout.addWidget(self.power_mode_label)
        layout.addWidget(self.power_mode_combo)
        self.refresh_label = QLabel("Laptop Refresh Rate: -- Hz")
        self.refresh_buttons_layout = QHBoxLayout()
        layout.addWidget(self.refresh_label)
        layout.addLayout(self.refresh_buttons_layout)
        self.refresh_supported_rates()
        self.backlight_label = QLabel("Keyboard Backlight: --")
        self.backlight_slider = QSlider(Qt.Horizontal)
        self.backlight_slider.setMinimum(0)
        self.backlight_slider.setMaximum(100)
        self.backlight_slider.setValue(50)
        self.backlight_slider.valueChanged.connect(self.set_backlight)
        layout.addWidget(self.backlight_label)
        layout.addWidget(self.backlight_slider)
        self.charge_label = QLabel("Battery Charge Limit: -- %")
        self.charge_slider = QSlider(Qt.Horizontal)
        self.charge_slider.setMinimum(50)
        self.charge_slider.setMaximum(100)
        self.charge_slider.setValue(100)
        self.charge_slider.valueChanged.connect(self.set_charge)
        layout.addWidget(self.charge_label)
        layout.addWidget(self.charge_slider)
        self.brightness_label = QLabel("Screen Brightness: -- %")
        self.brightness_slider = QSlider(Qt.Horizontal)
        self.brightness_slider.setMinimum(0)
        self.brightness_slider.setMaximum(100)
        self.brightness_slider.setValue(50)
        self.brightness_slider.valueChanged.connect(self.set_brightness)
        layout.addWidget(self.brightness_label)
        layout.addWidget(self.brightness_slider)
        self.setLayout(layout)
        self.update_power_mode_label()

    def refresh_supported_rates(self):
        for i in reversed(range(self.refresh_buttons_layout.count())):
            w = self.refresh_buttons_layout.itemAt(i).widget()
            if w:
                w.setParent(None)
        if not shutil.which("xrandr"):
            return
        out = run_command("xrandr --current")
        display = None
        for line in out.splitlines():
            if " connected" in line:
                display = line.split()[0]
                break
        if not display:
            return
        rates = set()
        collect=False
        for line in out.splitlines():
            if line.startswith(display + " "):
                collect=True
                continue
            if collect:
                if line.strip()=="" or not line.startswith("   "):
                    break
                parts=line.split()
                hz_candidate=None
                for part in parts:
                    if part.endswith("+") or part.endswith("*"):
                        part=part.rstrip("+*")
                    try:
                        if "." in part:
                            hz=float(part)
                            hz_candidate=int(hz)
                            rates.add(hz_candidate)
                    except:
                        pass
        rates=sorted(rates)
        for hz in rates:
            btn=QPushButton(f"{hz} Hz")
            btn.clicked.connect(lambda checked, hz=hz: self.set_refresh_rate(hz))
            self.refresh_buttons_layout.addWidget(btn)

    def update_power_mode_label(self):
        mode="Unknown"
        out = run_command("powerprofilesctl get")
        if out:
            mode=out.strip()
        self.power_mode_label.setText(f"Power Mode: {mode}")

    def update_availability(self):
        self.power_mode_combo.setEnabled(command_exists("powerprofilesctl"))
        self.refresh_buttons_layout.setEnabled(command_exists("xrandr"))
        self.backlight_slider.setEnabled(self._backlight_writable())
        self.charge_slider.setEnabled(self._charge_writable())
        self.brightness_slider.setEnabled(self._brightness_writable())

    def _backlight_writable(self):
        if command_exists("brightnessctl"):
            return True
        for b in glob.glob("/sys/class/leds/*/max_brightness") + glob.glob("/sys/class/leds/*kbd_backlight*/max_brightness"):
            if os.path.exists(b):
                return os.access(os.path.dirname(b) + "/brightness", os.W_OK) or os.access(os.path.dirname(b) + "/brightness", os.R_OK)
        return False

    def _charge_writable(self):
        if command_exists("tlp"):
            return True
        for bat in glob.glob("/sys/class/power_supply/*"):
            for f in ("charge_control_end_threshold","charge_control_limit","charge_control_end_percent"):
                if os.path.exists(os.path.join(bat,f)):
                    return os.access(os.path.join(bat,f), os.W_OK) or True
        return False

    def _brightness_writable(self):
        if command_exists("brightnessctl"):
            return True
        for bdir in glob.glob("/sys/class/backlight/*"):
            if os.path.isdir(bdir):
                maxf=os.path.join(bdir,"max_brightness")
                brightf=os.path.join(bdir,"brightness")
                if os.path.exists(maxf) and os.path.exists(brightf):
                    return os.access(brightf, os.W_OK) or True
        return False

    def set_power_mode(self, idx):
        mode=self.power_mode_combo.currentText()
        subprocess.Popen(["sudo","bash","./backend/vendors/set_power_mode.sh",mode])
        self.update_power_mode_label()

    def set_refresh_rate(self, v):
        self.refresh_label.setText(f"Laptop Refresh Rate: {v} Hz")
        subprocess.Popen(["bash","./backend/vendors/set_refresh_rate.sh",str(v)])

    def set_backlight(self, v):
        self.backlight_label.setText(f"Keyboard Backlight: {v} %")
        subprocess.Popen(["sudo","bash","./backend/vendors/set_backlight.sh",str(v)])

    def set_charge(self, v):
        self.charge_label.setText(f"Battery Charge Limit: {v} %")
        subprocess.Popen(["sudo","bash","./backend/vendors/set_charge_limit.sh",str(v)])

    def set_brightness(self, v):
        self.brightness_label.setText(f"Screen Brightness: {v} %")
        subprocess.Popen(["sudo","bash","./backend/vendors/set_brightness.sh",str(v)])

def command_exists(name):
    return shutil.which(name) is not None

class MainWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Performance Tweaker")
        self.resize(900,700)
        self.sudo_ok = request_sudo(self)
        self.init_ui()

    def init_ui(self):
        layout=QVBoxLayout()
        tabs=QTabWidget()
        self.cpu_tab=__import__('__main__').CpuTab(self.sudo_ok)
        self.gpu_tab=__import__('__main__').GpuTab(self.sudo_ok)
        self.general_tab=GeneralTab(self.sudo_ok)
        tabs.addTab(self.cpu_tab,"CPU")
        tabs.addTab(self.gpu_tab,"GPU")
        tabs.addTab(self.general_tab,"General")
        layout.addWidget(tabs)
        refresh_btn=QPushButton("Refresh detection and availability")
        refresh_btn.clicked.connect(self.refresh_all)
        layout.addWidget(refresh_btn)
        self.setLayout(layout)

    def refresh_all(self):
        self.cpu_tab.refresh_detection()
        self.gpu_tab.refresh_detection()
        self.cpu_tab.update_availability()
        self.gpu_tab.update_availability()
        self.general_tab.update_availability()

if __name__=="__main__":
    app=QApplication(sys.argv)
    w=MainWindow()
    w.show()
    sys.exit(app.exec_())
PY

chmod +x backend/detect/*.sh backend/vendors/*.sh ui/main.py

echo "install complete"
