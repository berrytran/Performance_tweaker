import os
import subprocess
import tkinter as tk
from tkinter import ttk

def read_file(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except:
        return "unknown"

def get_power_mode():
    try:
        out = subprocess.check_output(["powerprofilesctl", "get"]).decode().strip()
        return out
    except:
        return "unknown"

def set_power_mode(mode):
    try:
        subprocess.run(["powerprofilesctl", "set", mode])
    except:
        pass

def get_refresh_rates():
    try:
        out = subprocess.check_output(["xrandr"]).decode().splitlines()
        cur = []
        for line in out:
            if "*" in line:
                parts = line.split()
                for p in parts:
                    if "*" in p:
                        continue
                    if "." in p or p.isdigit():
                        cur.append(p.replace("+",""))
                break
        return list(set(cur))
    except:
        return []

def set_refresh_rate(rate):
    try:
        subprocess.run(["xrandr", "-r", rate])
    except:
        pass

root = tk.Tk()
root.title("Performance Tweaker")
root.geometry("600x400")

notebook = ttk.Notebook(root)
notebook.pack(fill="both", expand=True)

tab_general = ttk.Frame(notebook)
notebook.add(tab_general, text="General")

power_label = ttk.Label(tab_general, text="Power Mode:")
power_label.pack(pady=5)

power_var = tk.StringVar(value=get_power_mode())

power_menu = ttk.OptionMenu(tab_general, power_var, power_var.get(), "performance", "balanced", "power-saver")
power_menu.pack(pady=5)

def apply_power():
    set_power_mode(power_var.get())

ttk.Button(tab_general, text="Apply Power Mode", command=apply_power).pack(pady=5)

ttk.Label(tab_general, text="Refresh Rate:").pack(pady=5)

rates = get_refresh_rates()
rate_frame = ttk.Frame(tab_general)
rate_frame.pack(pady=5)

def rate_press(r):
    set_refresh_rate(r)

for r in rates:
    ttk.Button(rate_frame, text=r, command=lambda x=r: rate_press(x)).pack(side="left", padx=5)

root.mainloop()
