#!/usr/bin/env python3
import os
import sys
import subprocess

def ensure_root():
    if os.geteuid() != 0:
        try:
            # Ask for sudo password upfront
            subprocess.run(["sudo", "-v"], check=True)
        except subprocess.CalledProcessError:
            print("This app requires sudo privileges. Exiting.")
            sys.exit(1)

ensure_root()

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
        display = os.environ.get("DISPLAY")
        if shutil.which("nvidia-settings") and display:
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
