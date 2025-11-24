#!/usr/bin/env python3
import sys
import os
import shutil
import glob
import subprocess
import psutil
from PyQt5.QtWidgets import (
    QApplication, QWidget, QLabel, QVBoxLayout, QSlider, QTabWidget,
    QMessageBox, QPushButton, QComboBox, QHBoxLayout
)
from PyQt5.QtCore import Qt, QTimer
from PyQt5.QtWidgets import QApplication
app = QApplication(sys.argv)
app.setStyle("Fusion")

BASE_DIR = os.path.dirname(__file__)
DETECT_ALL = os.path.join(BASE_DIR, "backend", "detect", "all.sh")
VENDORS_DIR = os.path.join(BASE_DIR, "backend", "vendors")

def run_command(cmd, timeout=3, env=None):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, timeout=timeout, env=env).strip()
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

def command_exists(name):
    return shutil.which(name) is not None

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
        if os.path.isfile(DETECT_ALL):
            out = run_command(f"bash '{DETECT_ALL}'")
            for line in out.splitlines():
                if line.startswith("CPU_VENDOR="):
                    self.vendor_label.setText("CPU: " + line.split('=',1)[1].strip())

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
        if os.path.isfile(DETECT_ALL):
            out = run_command(f"bash '{DETECT_ALL}'")
            for line in out.splitlines():
                if line.startswith("GPU_VENDOR="):
                    self.vendor_label.setText("GPU: " + line.split('=',1)[1].strip())

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
        self.init_ui()
        self.update_availability()

    def init_ui(self):
        layout = QVBoxLayout()
        self.power_mode_label = QLabel("Power Mode: Unknown")
        self.power_mode_combo = QComboBox()
        self.power_mode_combo.addItems(["performance","balanced","power-saver"])
        self.power_mode_combo.currentTextChanged.connect(self.set_power_mode)
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
        collect = False
        for line in out.splitlines():
            if line.startswith(display + " "):
                collect = True
                continue
            if collect:
                if line.strip() == "" or not line.startswith("   "):
                    break
                parts = line.split()
                for p in parts:
                    s = p.rstrip("*+")
                    if s.count(".") == 1:
                        try:
                            hz = float(s)
                            rates.add(int(round(hz)))
                        except:
                            pass
        rates = sorted(rates)
        for hz in rates:
            btn = QPushButton(f"{hz} Hz")
            btn.clicked.connect(lambda checked, hz=hz: self.set_refresh_rate(hz))
            self.refresh_buttons_layout.addWidget(btn)

    def update_power_mode_label(self):
        out = run_command("powerprofilesctl get")
        mode = out.strip() if out else "Unknown"
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
                br = os.path.join(os.path.dirname(b), "brightness")
                if os.path.exists(br):
                    return os.access(br, os.W_OK) or os.access(br, os.R_OK)
        return False

    def _charge_writable(self):
        if command_exists("tlp"):
            return True
        for bat in glob.glob("/sys/class/power_supply/*"):
            for f in ("charge_control_end_threshold","charge_control_limit","charge_control_end_percent"):
                if os.path.exists(os.path.join(bat,f)):
                    return True
        return False

    def _brightness_writable(self):
        if command_exists("brightnessctl"):
            return True
        for bdir in glob.glob("/sys/class/backlight/*"):
            if os.path.isdir(bdir):
                maxf = os.path.join(bdir, "max_brightness")
                brightf = os.path.join(bdir, "brightness")
                if os.path.exists(maxf) and os.path.exists(brightf):
                    return True
        return False

    def set_power_mode(self, mode):
        self.power_mode_label.setText(f"Power Mode: {mode}")
        script = os.path.join(VENDORS_DIR, "set_power_mode.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, mode])
            except Exception:
                pass
        self.update_power_mode_label()

    def set_refresh_rate(self, hz):
        self.refresh_label.setText(f"Laptop Refresh Rate: {hz} Hz")
        script = os.path.join(VENDORS_DIR, "set_refresh_rate.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["bash", script, str(hz)])
            except Exception:
                pass

    def set_backlight(self, v):
        self.backlight_label.setText(f"Keyboard Backlight: {v} %")
        script = os.path.join(VENDORS_DIR, "set_backlight.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
            except Exception:
                pass

    def set_charge(self, v):
        self.charge_label.setText(f"Battery Charge Limit: {v} %")
        script = os.path.join(VENDORS_DIR, "set_charge_limit.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
            except Exception:
                pass

    def set_brightness(self, v):
        self.brightness_label.setText(f"Screen Brightness: {v} %")
        script = os.path.join(VENDORS_DIR, "set_brightness.sh")
        if os.path.isfile(script):
            try:
                subprocess.Popen(["sudo", "bash", script, str(v)])
            except Exception:
                pass

class MainWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Performance Tweaker")
        self.resize(900,700)
        self.sudo_ok = request_sudo(self)
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
        self.general_tab.update_availability()

def run():
    app = QApplication(sys.argv)
    w = MainWindow()
    w.show()
    app.exec()

if __name__ == "__main__":
    run()
