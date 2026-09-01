#!/usr/bin/env python3
"""XSIGHT 2-in-1 Dual Launcher (GUI).

Launch and control both the Python FastAPI backend and the Flutter Kiosk App
from a single unified desktop window with live streaming log consoles,
device selection, hot-reload controls, and health monitoring.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path
import tkinter as tk
from tkinter import messagebox, ttk

# Project paths
ROOT_DIR = Path(__file__).resolve().parent
SERVER_DIR = ROOT_DIR / "server"


def get_python_executable() -> str:
    """Find the best Python executable (checks virtualenvs first)."""
    candidates = [
        SERVER_DIR / ".venv" / "bin" / "python",
        SERVER_DIR / "venv" / "bin" / "python",
        ROOT_DIR / ".venv" / "bin" / "python",
        ROOT_DIR / "venv" / "bin" / "python",
    ]
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return str(c)
    return sys.executable


def detect_flutter_devices() -> list[dict]:
    """Run `flutter devices --machine` and parse the JSON device list."""
    try:
        result = subprocess.run(
            ["flutter", "devices", "--machine"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0 and result.stdout.strip():
            devices = json.loads(result.stdout.strip())
            return [d for d in devices if d.get("isSupported", False)]
    except Exception:
        pass
    return []


class XSightDualLauncher:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("XSIGHT — 2-in-1 Dual Launcher")
        self.root.geometry("1020x720")
        self.root.minsize(820, 580)

        # Style & Palette
        self.bg_dark = "#15202B"
        self.bg_panel = "#192734"
        self.bg_console = "#0F1419"
        self.accent_teal = "#00BA7C"
        self.accent_blue = "#1D9BF0"
        self.accent_red = "#F4212E"
        self.accent_orange = "#FF7A00"
        self.accent_yellow = "#FFD700"
        self.text_light = "#E7E9EA"
        self.text_dim = "#8899A6"

        self.root.configure(bg=self.bg_dark)

        # Process handles
        self.server_proc: subprocess.Popen | None = None
        self.flutter_proc: subprocess.Popen | None = None
        self.server_running = False
        self.flutter_running = False

        # Device list
        self.devices: list[dict] = []
        self.selected_device_id: str = ""
        self.selected_device_name: str = ""

        self._setup_ui()
        self._check_health_loop()

        # Handle window close
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)

        # Detect devices on startup (in background so the UI doesn't freeze)
        threading.Thread(target=self._refresh_devices_async, daemon=True).start()

    def _setup_ui(self):
        # ── 1. Top Header Bar ──────────────────────────────────────────
        header = tk.Frame(self.root, bg=self.bg_panel, padx=18, pady=12)
        header.pack(fill=tk.X, side=tk.TOP)

        title_box = tk.Frame(header, bg=self.bg_panel)
        title_box.pack(side=tk.LEFT)

        tk.Label(
            title_box,
            text="XSIGHT",
            font=("Helvetica", 16, "bold"),
            fg=self.accent_teal,
            bg=self.bg_panel,
        ).pack(side=tk.LEFT)

        tk.Label(
            title_box,
            text="  |  Thoracic AI Kiosk & Backend Control Station",
            font=("Helvetica", 11),
            fg=self.text_dim,
            bg=self.bg_panel,
        ).pack(side=tk.LEFT)

        # Status Chips
        self.status_box = tk.Frame(header, bg=self.bg_panel)
        self.status_box.pack(side=tk.RIGHT)

        self.server_badge = tk.Label(
            self.status_box,
            text="● Server: STOPPED",
            font=("Helvetica", 10, "bold"),
            fg=self.accent_red,
            bg=self.bg_panel,
            padx=8,
        )
        self.server_badge.pack(side=tk.LEFT)

        self.flutter_badge = tk.Label(
            self.status_box,
            text="● Flutter: STOPPED",
            font=("Helvetica", 10, "bold"),
            fg=self.accent_red,
            bg=self.bg_panel,
            padx=8,
        )
        self.flutter_badge.pack(side=tk.LEFT)

        # ── 2. Device Selection Bar ─────────────────────────────────────
        device_bar = tk.Frame(self.root, bg=self.bg_dark, padx=16, pady=6)
        device_bar.pack(fill=tk.X, side=tk.TOP)

        tk.Label(
            device_bar,
            text="📱 TARGET DEVICE:",
            font=("Helvetica", 9, "bold"),
            fg=self.accent_yellow,
            bg=self.bg_dark,
        ).pack(side=tk.LEFT, padx=(0, 6))

        # Device dropdown
        self.device_var = tk.StringVar(value="Scanning for devices…")
        self.device_combo = ttk.Combobox(
            device_bar,
            textvariable=self.device_var,
            state="readonly",
            width=52,
            font=("Helvetica", 10),
        )
        self.device_combo.pack(side=tk.LEFT, padx=4)
        self.device_combo.bind("<<ComboboxSelected>>", self._on_device_selected)

        # Refresh devices button
        self.btn_refresh = tk.Button(
            device_bar,
            text="🔄 Refresh Devices",
            font=("Helvetica", 9),
            bg="#22303C",
            fg=self.text_light,
            activebackground="#2C3E50",
            activeforeground="#FFFFFF",
            relief=tk.FLAT,
            padx=10,
            pady=4,
            cursor="hand2",
            command=self._refresh_devices_click,
        )
        self.btn_refresh.pack(side=tk.LEFT, padx=6)

        # Device info label (shows platform, SDK, etc)
        self.device_info_label = tk.Label(
            device_bar,
            text="",
            font=("Helvetica", 8),
            fg=self.text_dim,
            bg=self.bg_dark,
        )
        self.device_info_label.pack(side=tk.LEFT, padx=8)

        # ── 3. Primary Control Bar ──────────────────────────────────────
        ctrl_bar = tk.Frame(self.root, bg=self.bg_dark, padx=16, pady=10)
        ctrl_bar.pack(fill=tk.X, side=tk.TOP)

        # 2-in-1 Launch Both Button (Prominent)
        self.btn_both = tk.Button(
            ctrl_bar,
            text="🚀  LAUNCH BOTH (SERVER + FLUTTER)",
            font=("Helvetica", 11, "bold"),
            bg=self.accent_teal,
            fg="#FFFFFF",
            activebackground="#009663",
            activeforeground="#FFFFFF",
            relief=tk.FLAT,
            padx=14,
            pady=8,
            cursor="hand2",
            command=self.toggle_both,
        )
        self.btn_both.pack(side=tk.LEFT, padx=4)

        # Start Server Button
        self.btn_server = tk.Button(
            ctrl_bar,
            text="⚡  Start Server",
            font=("Helvetica", 10, "bold"),
            bg="#22303C",
            fg=self.text_light,
            activebackground="#2C3E50",
            activeforeground="#FFFFFF",
            relief=tk.FLAT,
            padx=12,
            pady=8,
            cursor="hand2",
            command=self.toggle_server,
        )
        self.btn_server.pack(side=tk.LEFT, padx=4)

        # Start Flutter Button
        self.btn_flutter = tk.Button(
            ctrl_bar,
            text="📱  Start Flutter App",
            font=("Helvetica", 10, "bold"),
            bg="#22303C",
            fg=self.text_light,
            activebackground="#2C3E50",
            activeforeground="#FFFFFF",
            relief=tk.FLAT,
            padx=12,
            pady=8,
            cursor="hand2",
            command=self.toggle_flutter,
        )
        self.btn_flutter.pack(side=tk.LEFT, padx=4)

        # Flutter Hot-Reload Buttons
        self.btn_reload = tk.Button(
            ctrl_bar,
            text="⚡ Reload (r)",
            font=("Helvetica", 9),
            bg="#192734",
            fg=self.accent_blue,
            relief=tk.FLAT,
            padx=8,
            pady=6,
            cursor="hand2",
            command=lambda: self.send_flutter_input("r"),
        )
        self.btn_reload.pack(side=tk.LEFT, padx=4)

        self.btn_restart = tk.Button(
            ctrl_bar,
            text="🔄 Restart (R)",
            font=("Helvetica", 9),
            bg="#192734",
            fg=self.accent_orange,
            relief=tk.FLAT,
            padx=8,
            pady=6,
            cursor="hand2",
            command=lambda: self.send_flutter_input("R"),
        )
        self.btn_restart.pack(side=tk.LEFT, padx=4)

        # Browser Link & Stop All
        tk.Button(
            ctrl_bar,
            text="🌐 Web Docs",
            font=("Helvetica", 9),
            bg="#192734",
            fg=self.text_dim,
            relief=tk.FLAT,
            padx=8,
            pady=6,
            cursor="hand2",
            command=lambda: webbrowser.open("http://localhost:8000/docs"),
        ).pack(side=tk.RIGHT, padx=4)

        self.btn_stop_all = tk.Button(
            ctrl_bar,
            text="🛑 Stop All",
            font=("Helvetica", 10, "bold"),
            bg="#38444D",
            fg=self.accent_red,
            activebackground="#4B5B67",
            relief=tk.FLAT,
            padx=10,
            pady=8,
            cursor="hand2",
            command=self.stop_all,
        )
        self.btn_stop_all.pack(side=tk.RIGHT, padx=4)

        # ── 4. Dual-Console View (Server on Left, Flutter on Right) ────
        main_pane = tk.PanedWindow(
            self.root, orient=tk.HORIZONTAL, bg=self.bg_dark, sashwidth=4
        )
        main_pane.pack(fill=tk.BOTH, expand=True, padx=12, pady=6)

        # Left Pane: Backend Server Console
        left_frame = tk.Frame(main_pane, bg=self.bg_panel)
        main_pane.add(left_frame, width=500)

        left_hdr = tk.Frame(left_frame, bg=self.bg_panel, padx=8, pady=6)
        left_hdr.pack(fill=tk.X)
        tk.Label(
            left_hdr,
            text="⚡ FASTAPI BACKEND CONSOLE (Port 8000)",
            font=("Helvetica", 9, "bold"),
            fg=self.accent_teal,
            bg=self.bg_panel,
        ).pack(side=tk.LEFT)
        tk.Button(
            left_hdr,
            text="Clear",
            font=("Helvetica", 8),
            fg=self.text_dim,
            bg=self.bg_panel,
            relief=tk.FLAT,
            command=lambda: self.clear_console(self.server_txt),
        ).pack(side=tk.RIGHT)

        self.server_txt = tk.Text(
            left_frame,
            bg=self.bg_console,
            fg="#A7F3D0",
            insertbackground="#A7F3D0",
            font=("DejaVu Sans Mono", 9),
            wrap=tk.WORD,
            padx=8,
            pady=8,
            relief=tk.FLAT,
        )
        server_scroll = tk.Scrollbar(
            left_frame, command=self.server_txt.yview, bg=self.bg_panel
        )
        self.server_txt.config(yscrollcommand=server_scroll.set)
        server_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.server_txt.pack(fill=tk.BOTH, expand=True)

        # Right Pane: Flutter App Console
        right_frame = tk.Frame(main_pane, bg=self.bg_panel)
        main_pane.add(right_frame, width=500)

        right_hdr = tk.Frame(right_frame, bg=self.bg_panel, padx=8, pady=6)
        right_hdr.pack(fill=tk.X)
        self.flutter_console_label = tk.Label(
            right_hdr,
            text="📱 FLUTTER APP CONSOLE",
            font=("Helvetica", 9, "bold"),
            fg=self.accent_blue,
            bg=self.bg_panel,
        )
        self.flutter_console_label.pack(side=tk.LEFT)
        tk.Button(
            right_hdr,
            text="Clear",
            font=("Helvetica", 8),
            fg=self.text_dim,
            bg=self.bg_panel,
            relief=tk.FLAT,
            command=lambda: self.clear_console(self.flutter_txt),
        ).pack(side=tk.RIGHT)

        self.flutter_txt = tk.Text(
            right_frame,
            bg=self.bg_console,
            fg="#BAE6FD",
            insertbackground="#BAE6FD",
            font=("DejaVu Sans Mono", 9),
            wrap=tk.WORD,
            padx=8,
            pady=8,
            relief=tk.FLAT,
        )
        flutter_scroll = tk.Scrollbar(
            right_frame, command=self.flutter_txt.yview, bg=self.bg_panel
        )
        self.flutter_txt.config(yscrollcommand=flutter_scroll.set)
        flutter_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.flutter_txt.pack(fill=tk.BOTH, expand=True)

        # ── 5. Bottom Footer ──────────────────────────────────────────
        footer = tk.Frame(self.root, bg=self.bg_panel, padx=14, pady=6)
        footer.pack(fill=tk.X, side=tk.BOTTOM)

        self.footer_label = tk.Label(
            footer,
            text=f"Python: {get_python_executable()}  |  Workspace: {ROOT_DIR}",
            font=("Helvetica", 8),
            fg=self.text_dim,
            bg=self.bg_panel,
        )
        self.footer_label.pack(side=tk.LEFT)

    # ── Device Detection ───────────────────────────────────────────────

    def _refresh_devices_async(self):
        """Detect devices in a background thread and update the UI."""
        self.root.after(0, lambda: self.device_var.set("⏳ Scanning for devices…"))
        self.root.after(0, lambda: self.btn_refresh.config(state=tk.DISABLED))

        devices = detect_flutter_devices()

        def _update():
            self.devices = devices
            if not devices:
                self.device_combo["values"] = ["(No devices found)"]
                self.device_var.set("(No devices found)")
                self.device_info_label.config(text="Connect a device or start an emulator, then refresh.")
                self.selected_device_id = ""
                self.selected_device_name = ""
            else:
                entries = []
                for d in devices:
                    name = d.get("name", "Unknown")
                    did = d.get("id", "")
                    platform = d.get("targetPlatform", "")
                    emulator = " (emulator)" if d.get("emulator", False) else ""
                    sdk = d.get("sdk", "")
                    # Short readable label
                    short_id = did if len(did) < 20 else did[:16] + "…"
                    entries.append(f"{name}  [{short_id}]  —  {platform}{emulator}")

                self.device_combo["values"] = entries
                # Auto-select the first device
                self.device_combo.current(0)
                self._on_device_selected(None)

            self.btn_refresh.config(state=tk.NORMAL)

        self.root.after(0, _update)

    def _refresh_devices_click(self):
        """Triggered by clicking the Refresh button."""
        threading.Thread(target=self._refresh_devices_async, daemon=True).start()

    def _on_device_selected(self, _event):
        """Handle device dropdown selection."""
        idx = self.device_combo.current()
        if idx < 0 or idx >= len(self.devices):
            return

        d = self.devices[idx]
        self.selected_device_id = d.get("id", "")
        self.selected_device_name = d.get("name", "Unknown")

        platform = d.get("targetPlatform", "")
        sdk = d.get("sdk", "")
        emulator = " (emulator)" if d.get("emulator", False) else " (physical)"
        caps = d.get("capabilities", {})
        hot = "hot-reload ✓" if caps.get("hotReload") else "hot-reload ✗"

        self.device_info_label.config(
            text=f"{sdk}{emulator}  •  {hot}",
            fg=self.accent_teal,
        )

    # ── Console Helpers ────────────────────────────────────────────────
    def append_log(self, text_widget: tk.Text, line: str):
        def _insert():
            text_widget.insert(tk.END, line)
            text_widget.see(tk.END)

        self.root.after(0, _insert)

    def clear_console(self, text_widget: tk.Text):
        text_widget.delete("1.0", tk.END)

    # ── Server Management ──────────────────────────────────────────────
    def start_server(self):
        if self.server_running:
            return

        py_bin = get_python_executable()
        self.append_log(
            self.server_txt, f"[LAUNCHER] Starting Server with {py_bin}...\n"
        )

        try:
            self.server_proc = subprocess.Popen(
                [py_bin, "main.py"],
                cwd=str(SERVER_DIR),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=dict(os.environ, PYTHONUNBUFFERED="1"),
            )
            self.server_running = True
            self.server_badge.config(
                text="● Server: RUNNING", fg=self.accent_teal
            )
            self.btn_server.config(text="⚡ Stop Server", bg=self.accent_red)

            # Start background reader thread
            threading.Thread(
                target=self._stream_output,
                args=(self.server_proc, self.server_txt, "Server"),
                daemon=True,
            ).start()
        except Exception as e:
            self.append_log(
                self.server_txt, f"[ERROR] Failed to start server: {e}\n"
            )

    def stop_server(self):
        if self.server_proc:
            try:
                self.server_proc.terminate()
                self.server_proc.wait(timeout=2)
            except Exception:
                self.server_proc.kill()
            self.server_proc = None

        self.server_running = False
        self.server_badge.config(text="● Server: STOPPED", fg=self.accent_red)
        self.btn_server.config(text="⚡ Start Server", bg="#22303C")
        self.append_log(self.server_txt, "[LAUNCHER] Server stopped.\n")

    def toggle_server(self):
        if self.server_running:
            self.stop_server()
        else:
            self.start_server()

    # ── Flutter Management ─────────────────────────────────────────────
    def start_flutter(self):
        if self.flutter_running:
            return

        # Validate device selection
        if not self.selected_device_id:
            self.append_log(
                self.flutter_txt,
                "[ERROR] No device selected! Select a target device from the dropdown above.\n",
            )
            return

        device_id = self.selected_device_id
        device_name = self.selected_device_name

        self.append_log(
            self.flutter_txt,
            f"[LAUNCHER] Launching Flutter on: {device_name}\n"
            f"[LAUNCHER] Device ID: {device_id}\n"
            f"[LAUNCHER] Command: flutter run -d {device_id} "
            f"--dart-define=BACKEND_BASE_URL=http://localhost:8000\n\n",
        )

        # Update console header to show target device
        self.flutter_console_label.config(
            text=f"📱 FLUTTER → {device_name}",
        )

        try:
            self.flutter_proc = subprocess.Popen(
                [
                    "flutter", "run",
                    "-d", device_id,
                    "--dart-define=BACKEND_BASE_URL=http://localhost:8000",
                ],
                cwd=str(ROOT_DIR),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            self.flutter_running = True
            self.flutter_badge.config(
                text=f"● Flutter: {device_name}", fg=self.accent_blue
            )
            self.btn_flutter.config(text="📱 Stop Flutter", bg=self.accent_red)

            # Disable device switching while running
            self.device_combo.config(state="disabled")
            self.btn_refresh.config(state=tk.DISABLED)

            # Start background reader thread
            threading.Thread(
                target=self._stream_output,
                args=(self.flutter_proc, self.flutter_txt, "Flutter"),
                daemon=True,
            ).start()
        except Exception as e:
            self.append_log(
                self.flutter_txt, f"[ERROR] Failed to start Flutter: {e}\n"
            )

    def stop_flutter(self):
        if self.flutter_proc:
            try:
                if self.flutter_proc.stdin:
                    self.flutter_proc.stdin.write("q\n")
                    self.flutter_proc.stdin.flush()
                self.flutter_proc.wait(timeout=3)
            except Exception:
                self.flutter_proc.kill()
            self.flutter_proc = None

        self.flutter_running = False
        self.flutter_badge.config(
            text="● Flutter: STOPPED", fg=self.accent_red
        )
        self.btn_flutter.config(text="📱 Start Flutter App", bg="#22303C")
        self.flutter_console_label.config(text="📱 FLUTTER APP CONSOLE")

        # Re-enable device switching
        self.device_combo.config(state="readonly")
        self.btn_refresh.config(state=tk.NORMAL)

        self.append_log(self.flutter_txt, "[LAUNCHER] Flutter stopped.\n")

    def toggle_flutter(self):
        if self.flutter_running:
            self.stop_flutter()
        else:
            self.start_flutter()

    def send_flutter_input(self, cmd: str):
        if self.flutter_proc and self.flutter_proc.stdin:
            try:
                self.flutter_proc.stdin.write(f"{cmd}\n")
                self.flutter_proc.stdin.flush()
                self.append_log(
                    self.flutter_txt, f"[COMMAND SENT: '{cmd}']\n"
                )
            except Exception as e:
                self.append_log(
                    self.flutter_txt, f"[ERROR] Send command failed: {e}\n"
                )

    # ── 2-in-1 Dual Control ───────────────────────────────────────────
    def toggle_both(self):
        if self.server_running and self.flutter_running:
            self.stop_all()
        else:
            if not self.selected_device_id:
                self.append_log(
                    self.flutter_txt,
                    "[ERROR] No device selected! Pick a target device first.\n",
                )
                return
            if not self.server_running:
                self.start_server()
            # Brief pause to let server bind port before launching app
            self.root.after(1200, lambda: self.start_flutter())

    def stop_all(self):
        self.stop_flutter()
        self.stop_server()

    # ── Output Stream Worker ───────────────────────────────────────────
    def _stream_output(
        self, proc: subprocess.Popen, text_widget: tk.Text, name: str
    ):
        try:
            if proc.stdout:
                for line in iter(proc.stdout.readline, ""):
                    if not line:
                        break
                    self.append_log(text_widget, line)
        except Exception:
            pass
        finally:
            if name == "Server" and self.server_running:
                self.root.after(0, self.stop_server)
            elif name == "Flutter" and self.flutter_running:
                self.root.after(0, self.stop_flutter)

    def _check_health_loop(self):
        """Periodic status update."""
        if self.server_running and self.server_proc and self.server_proc.poll() is not None:
            self.stop_server()
        if self.flutter_running and self.flutter_proc and self.flutter_proc.poll() is not None:
            self.stop_flutter()

        self.root.after(1500, self._check_health_loop)

    def on_closing(self):
        self.stop_all()
        self.root.destroy()


def main():
    root = tk.Tk()
    app = XSightDualLauncher(root)
    root.mainloop()


if __name__ == "__main__":
    main()
