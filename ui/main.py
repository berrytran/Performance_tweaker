#!/usr/bin/env python3
import sys
import os
import shutil
import glob
import subprocess
import psutil
from PyQt5.QtWidgets import (
    QApplication, QWidget, QLabel, QVBoxLayout, QSlider, QTabWidget,
    QMessageBox, QPushButton, QComboBox
)
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
    dlg.setText(
        "This app can control hardware and may need sudo for some actions.\n"
        "Enter your password in the terminal if you want full control.\n"
        "Continue without sudo will disable controls that require root."
    )
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
            if os.path.exists(pwm) and os.access(pwm, os.W_OK):
                return pwm
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
        power_ok = cpu_power_available() and self.sudo_ok and self.cpu_power_max is not None
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
        self.power_mode_combo.currentTextChanged.connect(self.set_power_mode)
        layout.addWidget(self.power_mode_label)
        layout.addWidget(self.power_mode_combo)

        self.brightness_label = QLabel("Brightness: --")
        self.brightness_slider = QSlider(Qt.Horizontal)
        self.brightness_slider.setMinimum(0)
        self.brightness_slider.setMaximum(100)
        self.brightness_slider.setValue(50)
        self.brightness_slider.valueChanged.connect(self.set_brightness)
        layout.addWidget(self.brightness_label)
        layout.addWidget(self.brightness_slider)

        self.refresh_label = QLabel("Refresh Rate: --")
        self.refresh_combo = QComboBox()
        self.refresh_combo.addItems(["60Hz","120Hz","144Hz","165Hz","240Hz"])
        self.refresh_combo.currentTextChanged.connect(self.set_refresh_rate)
        layout.addWidget(self.refresh_label)
        layout.addWidget(self.refresh_combo)

        self.charge_label = QLabel("Charge Limit: --")
        self.charge_slider = QSlider(Qt.Horizontal)
        self.charge_slider.setMinimum(0)
        self.charge_slider.setMaximum(100)
        self.charge_slider.setValue(80)
        self.charge_slider.valueChanged.connect(self.set_charge_limit)
        layout.addWidget(self.charge_label)
        layout.addWidget(self.charge_slider)

        self.setLayout(layout)

    def update_availability(self):
        self.power_mode_combo.setEnabled(command_exists("powerprofilesctl"))
        self.brightness_slider.setEnabled(self.sudo_ok and os.path.exists("/sys/class/backlight"))
        self.refresh_combo.setEnabled(self.sudo_ok)
        self.charge_slider.setEnabled(self.sudo_ok and os.path.exists("/sys/class/power_supply"))

    def set_power_mode(self, mode):
        self.power_mode_label.setText(f"Power Mode: {mode}")
        if command_exists("powerprofilesctl"):
            subprocess.Popen(["sudo","bash","./backend/vendors/set_power_mode.sh",mode])

    def set_brightness(self, value):
        self.brightness_label.setText(f"Brightness: {value}%")
        try:
            bl_files = glob.glob("/sys/class/backlight/*/brightness")
            for f in bl_files:
                subprocess.run(["sudo","tee", f], input=str(int(value*255/100)), text=True)
        except Exception:
            pass

    def set_refresh_rate(self, text):
        self.refresh_label.setText(f"Refresh Rate: {text}")

        subprocess.Popen(["sudo","bash","./backend/vendors/set_refresh.sh",text])

    def set_charge_limit(self, value):
        self.charge_label.setText(f"Charge Limit: {value}%")
        subprocess.Popen(["sudo","bash","./backend/vendors/set_charge.sh",str(value)])


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
        tabs.addTab(self.cpu_tab,"CPU")
        tabs.addTab(self.gpu_tab,"GPU")
        tabs.addTab(self.general_tab,"General")
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

if __name__=="__main__":
    app = QApplication(sys.argv)
    w = MainWindow()
    w.show()
    sys.exit(app.exec_())
