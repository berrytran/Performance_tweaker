#!/usr/bin/env bash
set -euo pipefail

rm -rf Perf_tweak
mkdir -p Perf_tweak
cd Perf_tweak

mkdir -p perf_tweaker/backend/detect
mkdir -p perf_tweaker/backend/vendors
mkdir -p perf_tweaker/icons
mkdir -p build/desktop

cat > perf_tweaker/__init__.py <<'PY'
# package marker
PY

cat > perf_tweaker/main.py <<'PY'
#!/usr/bin/env python3
import os
import sys
import time
import glob
import shutil
import subprocess
import psutil
from PyQt5.QtWidgets import (
    QApplication, QWidget, QLabel, QVBoxLayout, QHBoxLayout,
    QSlider, QTabWidget, QPushButton, QMessageBox, QComboBox
)
from PyQt5.QtCore import Qt, QTimer, QThread, pyqtSignal

BASE_DIR = os.path.dirname(__file__)
DETECT_ALL = os.path.join(BASE_DIR, "backend", "detect", "all.sh")
VENDORS_DIR = os.path.join(BASE_DIR, "backend", "vendors")

def run_command(cmd, timeout=3, env=None):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, timeout=timeout, env=env).strip()
    except Exception:
        return ""

def request_sudo_dialog(parent=None):
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
    dlg.setText("Some controls require root. Enter your password in the terminal if you want full control.\nPress Retry to try again, or Continue to run without root.")
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
            if ("nvidia" in low) or ("amd" in low) or ("radeon" in low) or ("ati " in low):
                return True
    return False

def nvidia_available():
    return shutil.which("nvidia-smi") or shutil.which("nvidia-settings")

def rocm_available():
    return shutil.which("rocm-smi")

def gpu_fan_available():
    if not has_dedicated_gpu():
        return False
    if nvidia_available() or rocm_available():
        return True
    if os.path.isfile(os.path.join(VENDORS_DIR, "set_gpu_power.sh")):
        return True
    return False

def cpu_power_available():
    cur, mx = find_powercap_current_max()
    if mx is not None:
        return True
    if os.path.isfile(os.path.join(VENDORS_DIR, "set_cpu_power.sh")):
        return True
    return False

def parse_xrandr_rates():
    out = run_command("xrandr --current")
    if not out:
        return []
    lines = out.splitlines()
    display = None
    for line in lines:
        if " connected" in line:
            display = line.split()[0]
            break
    if not display:
        return []
    rates = []
    collecting = False
    for line in lines:
        if line.startswith(display + " "):
            collecting = True
            continue
        if collecting:
            if line.strip() == "" or not (line.startswith("   ") or line.startswith("\t")):
                break
            parts = line.split()
            for token in parts[1:]:
                s = token.rstrip("*+")
                try:
                    f = float(s)
                    rates.append(f)
                except Exception:
                    pass
    if not rates:
        for line in lines:
            for token in line.split():
                try:
                    f = float(token.rstrip("*+"))
                    rates.append(f)
                except Exception:
                    pass
    if not rates:
        return []
    rates = sorted(set(rates))
    merged = []
    eps = 0.25
    for r in rates:
        if not merged:
            merged.append(r)
            continue
        if abs(r - merged[-1]) <= eps:
            merged[-1] = (merged[-1] + r) / 2.0
        else:
            merged.append(r)
    out = []
    seen = set()
    for r in merged:
        label = int(round(r))
        if label in seen:
            continue
        seen.add(label)
        out.append((label, r))
    return out

def set_refresh_rate_hz(hz):
    script = os.path.join(VENDORS_DIR, "set_refresh_rate.sh")
    if os.path.isfile(script):
        try:
            subprocess.Popen(["bash", script, str(hz)])
            return True
        except Exception:
            return False
    out = run_command("xrandr --current")
    if not out:
        return False
    display = None
    for line in out.splitlines():
        if " connected" in line:
            display = line.split()[0]
            break
    if not display:
        return False
    mode = None
    lines = run_command("xrandr").splitlines()
    collect = False
    for line in lines:
        if line.startswith(display + " "):
            collect = True
            continue
        if collect:
            if line.strip() == "" or not (line.startswith("   ") or line.startswith("\t")):
                break
            parts = line.split()
            for p in parts:
                s = p.rstrip("*+")
                try:
                    f = float(s)
                    if abs(f - float(hz)) < 0.5:
                        mode = parts[0]
                        break
                except Exception:
                    pass
            if mode:
                break
    if mode:
        return run_command(f"xrandr --output {display} --mode {mode} --rate {hz}") != ""
    return run_command(f"xrandr --output {display} --rate {hz}") != ""

def is_on_ac():
    for p in glob.glob("/sys/class/power_supply/*"):
        try:
            tfile = os.path.join(p, "type")
            if not os.path.exists(tfile):
                continue
            t = open(tfile).read().strip().lower()
            if "mains" in t or "ac" in t or "line" in t:
                onlinef = os.path.join(p, "online")
                if os.path.exists(onlinef):
                    v = open(onlinef).read().strip()
                    return v == "1"
        except Exception:
            continue
    out = run_command("acpi -a", timeout=1)
    if out:
        return "on-line" in out or "on line" in out
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
        self.temp_freq_label = QLabel("Temp: --    Freq: --")
        layout.addWidget(self.temp_freq_label)
        cur, mx = find_powercap_current_max()
        self.cpu_power_cur = cur
        self.cpu_power_max = int(mx) if mx is not None else None
        if self.cpu_power_max is not None:
            initial = int(self.cpu_power_cur) if self.cpu_power_cur is not None else (self.cpu_power_max // 2)
            txt = f"CPU Power: {initial} W / {self.cpu_power_max} W"
        else:
            initial = 1
            txt = "CPU Power: not adjustable"
        self.cpu_power_label = QLabel(txt)
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
        if os.path.isfile(DETECT_ALL):
            out = run_command(f"bash '{DETECT_ALL}'")
            for line in out.splitlines():
                if line.startswith("CPU_VENDOR="):
                    self.vendor_label.setText("CPU: " + line.split("=",1)[1].strip())

    def update_live(self):
        cpu_temp = run_command("sensors | awk -F: '/Package id 0|Core 0|Tdie|Tctl/ {print $2; exit}'").strip()
        freq = None
        try:
            f = psutil.cpu_freq()
            if f and f.current:
                freq = int(f.current)
        except Exception:
            freq = None
        temp_text = cpu_temp if cpu_temp else "--"
        freq_text = f"{freq} MHz" if freq else "--"
        self.temp_freq_label.setText(f"Temp: {temp_text}    Freq: {freq_text}")
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
            self.cpu_fan_label.setText("CPU Fan: settable via " + os.path.basename(pwm))
        else:
            self.cpu_fan_label.setText("CPU Fan: not adjustable")

    def update_availability(self):
        power_ok = cpu_power_available() and self.sudo_ok and self.cpu_power_max is not None
        fan_ok = (find_writable_hwmon_pwm() is not None) and self.sudo_ok
        self.cpu_power_slider.setEnabled(bool(power_ok))
        self.cpu_fan_slider.setEnabled(bool(fan_ok))

    def on_power_change(self, v):
        if self.cpu_power_max is None or not self.cpu_power_slider.isEnabled():
            return
        self.cpu_power_label.setText(f"CPU Power: {v} W / {self.cpu_power_max} W")
        script = os.path.join(VENDORS_DIR, "set_cpu_power.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
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
                subprocess.Popen(["sudo", "sh", "-c", f"echo {val} > '{pwm}'"])
                return
            except Exception:
                pass
        script = os.path.join(VENDORS_DIR, "set_fan.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
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
        self.temp_util_label = QLabel("Temp: --    Util: --")
        layout.addWidget(self.temp_util_label)
        self.gpu_power_label = QLabel("GPU Power: --")
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
        if os.path.isfile(DETECT_ALL):
            out = run_command(f"bash '{DETECT_ALL}'")
            for line in out.splitlines():
                if line.startswith("GPU_VENDOR="):
                    self.vendor_label.setText("GPU: " + line.split("=",1)[1].strip())

    def update_live(self):
        if shutil.which("nvidia-smi"):
            gtemp = run_command("nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null").strip()
            util = run_command("nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null").strip()
            if gtemp:
                self.temp_util_label.setText(f"Temp: {gtemp} °C    Util: {util if util else '--'}")
        elif shutil.which("rocm-smi"):
            gtemp = run_command("rocm-smi --showtemp 2>/dev/null").strip()
            if gtemp:
                self.temp_util_label.setText(f"Temp: {gtemp}")
        else:
            self.temp_util_label.setText("Temp: --    Util: --")
        if has_dedicated_gpu():
            self.gpu_fan_label.setText("GPU Fan: available" if gpu_fan_available() else "GPU Fan: control method missing")
            self.gpu_power_label.setText("GPU Power: adjustable" if gpu_fan_available() else "GPU Power: control method missing")
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
        self.gpu_power_label.setText(f"GPU Power: {v} %")
        script = os.path.join(VENDORS_DIR, "set_gpu_power.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
            except Exception:
                pass

    def on_fan_change(self, v):
        if not self.gpu_fan_slider.isEnabled():
            return
        self.gpu_fan_label.setText(f"GPU Fan: {v} %")
        if shutil.which("nvidia-settings") and os.environ.get("DISPLAY"):
            try:
                display = os.environ.get("DISPLAY")
            except Exception:
                display = None
        if display:
            try:
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
        script = os.path.join(VENDORS_DIR, "set_gpu_power.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
            except Exception:
                pass

class GeneralTab(QWidget):
    def __init__(self, sudo_ok):
        super().__init__()
        self.sudo_ok = bool(sudo_ok)
        self.user_selected_rate = None
        self.auto_mode = False
        self.rates = []
        self.init_ui()
        self.populate_rates()
        self.power_timer = QTimer()
        self.power_timer.timeout.connect(self.on_power_tick)
        self.power_timer.start(2000)
        self.last_ac = is_on_ac()

    def init_ui(self):
        layout = QVBoxLayout()
        row = QHBoxLayout()
        self.power_mode_label = QLabel("Power Mode: Unknown")
        self.power_mode_combo = QComboBox()
        self.power_mode_combo.addItems(["performance", "balanced", "power-saver"])
        self.power_mode_combo.currentIndexChanged.connect(self.on_power_mode_change)
        row.addWidget(self.power_mode_label)
        row.addWidget(self.power_mode_combo)
        layout.addLayout(row)
        self.rate_label = QLabel("Refresh Rate: --")
        self.rate_buttons_layout = QHBoxLayout()
        layout.addWidget(self.rate_label)
        layout.addLayout(self.rate_buttons_layout)
        self.auto_btn = QPushButton("Auto: off")
        self.auto_btn.setCheckable(True)
        self.auto_btn.clicked.connect(self.toggle_auto)
        layout.addWidget(self.auto_btn)
        gs = QHBoxLayout()
        self.gpu_switch_label = QLabel("GPU switching:")
        self.gpu_switch_combo = QComboBox()
        self.gpu_switch_combo.addItems(["auto","nvidia","intel","hybrid","off"])
        self.gpu_switch_combo.currentIndexChanged.connect(self.on_gpu_switch_change)
        gs.addWidget(self.gpu_switch_label)
        gs.addWidget(self.gpu_switch_combo)
        layout.addLayout(gs)
        self.backlight_label = QLabel("Backlight: --")
        self.backlight_slider = QSlider(Qt.Horizontal)
        self.backlight_slider.setMinimum(0)
        self.backlight_slider.setMaximum(100)
        self.backlight_slider.setValue(50)
        self.backlight_slider.valueChanged.connect(self.set_backlight)
        layout.addWidget(self.backlight_label)
        layout.addWidget(self.backlight_slider)
        self.charge_label = QLabel("Charge limit: --")
        self.charge_slider = QSlider(Qt.Horizontal)
        self.charge_slider.setMinimum(50)
        self.charge_slider.setMaximum(100)
        self.charge_slider.setValue(100)
        self.charge_slider.valueChanged.connect(self.set_charge)
        layout.addWidget(self.charge_label)
        layout.addWidget(self.charge_slider)
        self.brightness_label = QLabel("Brightness: --")
        self.brightness_slider = QSlider(Qt.Horizontal)
        self.brightness_slider.setMinimum(0)
        self.brightness_slider.setMaximum(100)
        self.brightness_slider.setValue(50)
        self.brightness_slider.valueChanged.connect(self.set_brightness)
        layout.addWidget(self.brightness_label)
        layout.addWidget(self.brightness_slider)
        self.setLayout(layout)
        self.update_power_mode_label()
        self.update_gpu_switch_availability()

    def populate_rates(self):
        while self.rate_buttons_layout.count():
            w = self.rate_buttons_layout.takeAt(0).widget()
            if w:
                w.setParent(None)
        self.rates = parse_xrandr_rates()
        if not self.rates:
            lbl = QLabel("No display or xrandr missing")
            self.rate_buttons_layout.addWidget(lbl)
            return
        for (label, precise) in self.rates:
            btn = QPushButton(f"{label} Hz")
            btn.clicked.connect(lambda _, hz=label: self.user_pick(hz))
            self.rate_buttons_layout.addWidget(btn)

    def user_pick(self, hz):
        self.user_selected_rate = hz
        set_refresh_rate_hz(hz)
        self.rate_label.setText(f"Refresh Rate: {hz} Hz")

    def toggle_auto(self):
        self.auto_mode = self.auto_btn.isChecked()
        self.auto_btn.setText("Auto: on" if self.auto_mode else "Auto: off")
        if self.auto_mode and not is_on_ac():
            if self.rates:
                lowest = min(self.rates, key=lambda x: x[1])[0]
                set_refresh_rate_hz(lowest)
                self.rate_label.setText(f"Refresh Rate: {lowest} Hz (auto)")
        elif not self.auto_mode and self.user_selected_rate:
            set_refresh_rate_hz(self.user_selected_rate)
            self.rate_label.setText(f"Refresh Rate: {self.user_selected_rate} Hz")

    def on_power_mode_change(self, idx):
        mode = self.power_mode_combo.currentText()
        script = os.path.join(VENDORS_DIR, "set_power_mode.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, mode])
            except Exception:
                pass
        self.update_power_mode_label()

    def update_power_mode_label(self):
        # prefer platform_profile to avoid gi dependency; fallback to powerprofilesctl if present
        pp = "/sys/firmware/acpi/platform_profile"
        if os.path.exists(pp):
            try:
                with open(pp, "r") as f:
                    val = f.read().strip()
                    self.power_mode_label.setText(f"Power Mode: {val}")
                    return
            except Exception:
                pass
        out = run_command("powerprofilesctl get")
        mode = out.strip() if out else "Unknown"
        self.power_mode_label.setText(f"Power Mode: {mode}")

    def set_backlight(self, v):
        self.backlight_label.setText(f"Backlight: {v} %")
        script = os.path.join(VENDORS_DIR, "set_backlight.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
            except Exception:
                pass

    def set_charge(self, v):
        self.charge_label.setText(f"Charge limit: {v} %")
        script = os.path.join(VENDORS_DIR, "set_charge_limit.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
            except Exception:
                pass

    def set_brightness(self, v):
        self.brightness_label.setText(f"Brightness: {v} %")
        script = os.path.join(VENDORS_DIR, "set_brightness.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
            except Exception:
                pass

    def on_gpu_switch_change(self, idx):
        choice = self.gpu_switch_combo.currentText()
        script = os.path.join(VENDORS_DIR, "set_gpu_switch.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, choice])
            except Exception:
                pass

    def update_gpu_switch_availability(self):
        script = os.path.join(VENDORS_DIR, "set_gpu_switch.sh")
        avail = os.path.isfile(script)
        hw = has_dedicated_gpu()
        self.gpu_switch_combo.setEnabled(avail and hw and self.sudo_ok)
        if not hw:
            self.gpu_switch_combo.setToolTip("No dGPU detected — switching not applicable")
        elif not avail:
            self.gpu_switch_combo.setToolTip("GPU switching backend missing; run installer to add backends")

    def on_power_tick(self):
        ac = is_on_ac()
        if ac != getattr(self, "last_ac", None):
            self.last_ac = ac
            if self.auto_mode:
                if not ac and self.rates:
                    lowest = min(self.rates, key=lambda x: x[1])[0]
                    set_refresh_rate_hz(lowest)
                    self.rate_label.setText(f"Refresh Rate: {lowest} Hz (auto)")
                elif ac and self.user_selected_rate:
                    set_refresh_rate_hz(self.user_selected_rate)
                    self.rate_label.setText(f"Refresh Rate: {self.user_selected_rate} Hz")
        self.update_power_mode_label()

class MainWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Performance Tweaker")
        self.resize(920, 520)
        self.sudo_ok = request_sudo_dialog(self)
        self.init_ui()

    def init_ui(self):
        layout = QVBoxLayout()
        tabs = QTabWidget()
        self.cpu_tab = CpuTab(self.sudo_ok)
        self.gpu_tab = GpuTab(self.sudo_ok)
        self.general_tab = GeneralTab(self.sudo_ok)
        tabs.addTab(self.cpu_tab, "CPU")
        tabs.addTab(self.gpu_tab, "GPU")
        tabs.addTab(self.general_tab, "General")
        layout.addWidget(tabs)
        refresh_btn = QPushButton("Refresh detection and availability")
        refresh_btn.clicked.connect(self.refresh_all)
        layout.addWidget(refresh_btn)
        self.setLayout(layout)

    def refresh_all(self):
        self.cpu_tab.refresh_detection()
        self.gpu_tab.refresh_detection()
        self.cpu_tab.update_availability()
        self.gpu_tab.update_availability()
        self.general_tab.populate_rates()
        self.general_tab.update_power_mode_label()
        self.general_tab.update_gpu_switch_availability()

def run():
    app = QApplication(sys.argv)
    w = MainWindow()
    w.show()
    sys.exit(app.exec_())

if __name__ == "__main__":
    run()
PY

cat > perf_tweaker/backend/detect/all.sh <<'SH'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
"$DIR/cpu.sh"
"$DIR/gpu.sh"
"$DIR/system.sh"
SH

cat > perf_tweaker/backend/detect/cpu.sh <<'SH'
#!/usr/bin/env bash
if command -v lscpu >/dev/null 2>&1; then
  lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print "CPU_VENDOR="$2; exit}'
else
  grep -m1 -i 'model name' /proc/cpuinfo | awk -F': ' '{print "CPU_VENDOR="$2}'
fi
SH

cat > perf_tweaker/backend/detect/gpu.sh <<'SH'
#!/usr/bin/env bash
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
SH

cat > perf_tweaker/backend/detect/system.sh <<'SH'
#!/usr/bin/env bash
if [ -f /sys/devices/virtual/dmi/id/sys_vendor ]; then
  echo "SYS_VENDOR=$(cat /sys/devices/virtual/dmi/id/sys_vendor)"
else
  echo "SYS_VENDOR=unknown"
fi
SH

cat > perf_tweaker/backend/vendors/set_refresh_rate.sh <<'SH'
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
xrandr --output "$OUT" --rate "$HZ" >/dev/null 2>&1 && echo "OK" && exit 0
MODE="$(xrandr | awk -v out="$OUT" -v hz="$HZ" '
  $0 ~ ("^" out " ") {flag=1; next}
  flag && $0 ~ /^[ \t]+[0-9]/ {
    for(i=1;i<=NF;i++) if($i ~ hz) {print $1; exit}
  }
')"
if [ -n "$MODE" ]; then
  xrandr --output "$OUT" --mode "$MODE" --rate "$HZ" >/dev/null 2>&1 && echo "OK" && exit 0
fi
echo "UNSUPPORTED"
exit 2
SH

cat > perf_tweaker/backend/vendors/set_cpu_power.sh <<'SH'
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
  fi
fi
if [ $written -eq 1 ]; then
  echo "OK"
else
  echo "UNSUPPORTED"
  exit 2
fi
SH

cat > perf_tweaker/backend/vendors/set_fan.sh <<'SH'
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
SH

cat > perf_tweaker/backend/vendors/set_gpu_power.sh <<'SH'
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
SH

cat > perf_tweaker/backend/vendors/set_backlight.sh <<'SH'
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
SH

cat > perf_tweaker/backend/vendors/set_charge_limit.sh <<'SH'
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
SH

cat > perf_tweaker/backend/vendors/set_brightness.sh <<'SH'
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
SH

cat > perf_tweaker/backend/vendors/set_power_mode.sh <<'SH'
#!/usr/bin/env bash
MODE="$1"
if [ -z "$MODE" ]; then
  echo "Usage: $0 <performance|balanced|power-saver>"
  exit 1
fi
pp="/sys/firmware/acpi/platform_profile"
if [ -w "$pp" ]; then
  echo "$MODE" | sudo tee "$pp" >/dev/null 2>&1 && echo "OK" && exit 0
fi
if command -v powerprofilesctl >/dev/null 2>&1; then
  sudo powerprofilesctl set "$MODE" && echo "OK" && exit 0
fi
echo "UNSUPPORTED"
exit 2
SH

cat > perf_tweaker/backend/vendors/set_gpu_switch.sh <<'SH'
#!/usr/bin/env bash
choice="$1"
if [ -z "$choice" ]; then
  echo "Usage: $0 <auto|nvidia|intel|hybrid|off>"
  exit 1
fi
if command -v prime-select >/dev/null 2>&1; then
  case "$choice" in
    nvidia) sudo prime-select nvidia && echo "OK" && exit 0;;
    intel) sudo prime-select intel && echo "OK" && exit 0;;
    hybrid|on-demand) sudo prime-select on-demand && echo "OK" && exit 0;;
    auto) echo "OK" && exit 0;;
  esac
fi
if command -v optimus-manager >/dev/null 2>&1; then
  case "$choice" in
    nvidia) sudo optimus-manager --switch nvidia && echo "OK" && exit 0;;
    intel) sudo optimus-manager --switch intel && echo "OK" && exit 0;;
    hybrid) sudo optimus-manager --switch hybrid && echo "OK" && exit 0;;
    auto) echo "OK" && exit 0;;
  esac
fi
if command -v switcherooctl >/dev/null 2>&1; then
  echo "switcherooctl present; manual switching may be required" && exit 0
fi
echo "UNSUPPORTED"
exit 2
SH

cat > perf_tweaker/backend/install_backends.sh <<'SH'
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
SH

chmod +x perf_tweaker/backend/detect/*.sh perf_tweaker/backend/vendors/*.sh perf_tweaker/backend/install_backends.sh perf_tweaker/main.py

cat > run.py <<'PY'
#!/usr/bin/env python3
from perf_tweaker.main import run
if __name__ == "__main__":
    run()
PY

cat > pyproject.toml <<'TOML'
[project]
name = "perf-tweaker"
version = "0.1.0"
description = "Perf Tweaker minimal"
authors = [{name = "you"}]
dependencies = ["PyQt5", "psutil"]
TOML

cat > build/desktop/perf-tweaker.desktop <<'DESK'
[Desktop Entry]
Name=Perf Tweaker
Exec=python3 /path/to/Perf_tweak/run.py
Icon=perf_tweaker
Type=Application
Categories=Utility;System;
StartupNotify=true
DESK

echo "Rebuild done."
echo ""
echo "Important next steps (read):"
echo "  1) Run installer to install OS-level dependencies (this will install GObject Introspection / gi):"
echo "       sudo bash perf_tweaker/backend/install_backends.sh"
echo "  2) Create and activate a virtualenv and install Python deps:"
echo "       python3 -m venv .venv"
echo "       source .venv/bin/activate"
echo "       pip install -U pip"
echo "       pip install PyQt5 psutil"
echo "  3) Run the app:"
echo "       python3 run.py"
echo ""
echo "If installer cannot find or install vendor GPU packages (NVIDIA/ROCm) you'll need to add vendor repos or use distribution-specific packages. The installer reports notes and continues."
