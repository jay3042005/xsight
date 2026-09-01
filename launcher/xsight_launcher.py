"""XSIGHT Server Launcher for Windows.

Standalone GUI launcher (built to .exe with PyInstaller). Drop it in the
``server`` folder next to ``main.py`` and run it -- no venv needed, it uses
the system Python 3.12 install.

Features:
- Auto-detects its own folder (finds main.py even if the exe is moved around)
- Runs the backend with system Python 3.12 (Program Files\\Python312, py
  launcher, or PATH -- whichever is found first)
- Shows the machine's LAN IP so kiosk devices know where to point
- Pings /health every 2 s and shows ACTIVE (green) with latency or DOWN (red)
- Live log console, Start/Stop/Restart buttons, one-click firewall rule
"""

from __future__ import annotations

import os
import queue
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser
from pathlib import Path

IS_WINDOWS = os.name == "nt"
CREATE_NO_WINDOW = 0x08000000 if IS_WINDOWS else 0
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def _msgbox_error(title: str, text: str) -> None:
    try:
        import tkinter as tk
        from tkinter import messagebox

        root = tk.Tk()
        root.withdraw()
        messagebox.showerror(title, text)
    except Exception:
        pass


try:
    import tkinter as tk
    from tkinter import font as tkfont
    from tkinter import scrolledtext, ttk
except Exception:  # pragma: no cover - only on broken Python installs
    _msgbox_error(
        "XSIGHT Launcher", "tkinter is not available in this Python install.\n"
        "Reinstall Python 3.12 with 'tcl/tk and IDLE' checked."
    )
    raise SystemExit(1)


# --------------------------------------------------------------------------
# Discovery helpers
# --------------------------------------------------------------------------

def app_base_dir() -> Path:
    """Folder the exe (or this script) lives in."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def looks_like_server_dir(path: Path) -> bool:
    return (path / "main.py").is_file() and (path / "app").is_dir()


def find_server_dir() -> Path | None:
    """Auto-detect the server folder from wherever the exe was placed."""
    base = app_base_dir()
    # 1) Right here (exe dropped into server/)
    if looks_like_server_dir(base):
        return base
    # 2) Walk up (exe in a subfolder of the project)
    for parent in base.parents:
        if looks_like_server_dir(parent):
            return parent
    # 3) Shallow search downward (exe next to the extracted backup folder,
    #    e.g. Downloads\\xsight_launcher.exe while the server lives two
    #    levels down inside "xsight backup_20260824 150622\\server")
    limit = 3
    frontier = [base]
    depth = 0
    while frontier and depth < limit:
        nxt: list[Path] = []
        for d in frontier:
            try:
                entries = list(d.iterdir())
            except OSError:
                continue
            for e in entries:
                if e.is_dir():
                    if looks_like_server_dir(e):
                        return e
                    nxt.append(e)
        frontier = nxt
        depth += 1
    return None


def find_python() -> tuple[list[str] | None, str]:
    """Locate system Python 3.12 (no venv). Returns (argv_list, display)."""
    candidates = [
        Path(r"C:\Program Files\Python312\python.exe"),
        Path(r"C:\Program Files (x86)\Python312\python.exe"),
        Path(os.environ.get("LOCALAPPDATA", ""))
        / "Programs" / "Python" / "Python312" / "python.exe",
    ]
    for c in candidates:
        if c.is_file():
            return [str(c)], str(c)

    py = shutil.which("py")
    if py:
        r = subprocess.run(
            [py, "-3.12", "--version"],
            capture_output=True, text=True, creationflags=CREATE_NO_WINDOW,
        )
        if r.returncode == 0 and "3.12" in (r.stdout + r.stderr):
            return [py, "-3.12"], f"{py} -3.12"

    exe = shutil.which("python") or shutil.which("python3")
    if exe:
        r = subprocess.run(
            [exe, "--version"],
            capture_output=True, text=True, creationflags=CREATE_NO_WINDOW,
        )
        ver = (r.stdout + r.stderr).strip()
        if r.returncode == 0 and ("3.1" in ver):
            return [exe], f"{exe}  ({ver})"
    return None, "Python 3.12 not found"


def read_port(server_dir: Path) -> int:
    env_file = server_dir / ".env"
    default = 8000
    if env_file.is_file():
        try:
            m = re.search(
                r"^XSIGHT_PORT\s*=\s*(\d+)",
                env_file.read_text(encoding="utf-8", errors="replace"),
                re.MULTILINE,
            )
            if m:
                return int(m.group(1))
        except OSError:
            pass
    val = os.getenv("XSIGHT_PORT")
    if val and val.isdigit():
        return int(val)
    return default


def local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1.0)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        pass
    try:
        return socket.gethostbyname(socket.gethostname())
    except OSError:
        return "127.0.0.1"


# --------------------------------------------------------------------------
# GUI
# --------------------------------------------------------------------------

class LauncherApp:
    PING_INTERVAL_MS = 2000
    LOG_MAX_LINES = 800

    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.proc: subprocess.Popen | None = None
        self.log_q: queue.Queue[str] = queue.Queue()
        self.ping_job = ""
        self.last_ok_ping: float | None = None

        self.server_dir = find_server_dir()
        self.python_argv, self.python_display = find_python()
        self.port = read_port(self.server_dir) if self.server_dir else 8000
        self.lan_ip = local_ip()

        self._build_ui()

        if self.server_dir is None:
            self._set_status("error", "SERVER FOLDER NOT FOUND")
            self.log("[!] Could not auto-detect the server folder.\n"
                     "    Put this launcher inside the 'server' folder "
                     "(next to main.py).\n")
        elif self.python_argv is None:
            self._set_status("error", "PYTHON 3.12 NOT FOUND")
            self.log("[!] Install Python 3.12 (check 'Add to PATH'), then "
                     "reopen this launcher.\n")
        else:
            self.log(f"[i] Server folder : {self.server_dir}\n")
            self.log(f"[i] Python       : {self.python_display}\n")
            self.root.after(400, self.start_server)

        self.root.after(80, self._drain_log_queue)
        self._schedule_ping()

    # ---------------- UI ----------------

    def _build_ui(self) -> None:
        self.root.title("XSIGHT Server Launcher")
        self.root.geometry("860x640")
        self.root.minsize(720, 520)
        self.root.configure(bg="#10151d")

        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TButton", padding=6)
        style.configure("TFrame", background="#10151d")
        style.configure("TLabel", background="#10151d",
                        foreground="#dbe4ee", font=("Segoe UI", 10))
        style.configure("Value.TLabel", foreground="#ffffff",
                        font=("Segoe UI", 10, "bold"))
        style.configure("Header.TLabel", foreground="#7fd1ff",
                        font=("Segoe UI", 15, "bold"))

        outer = ttk.Frame(self.root, padding=14)
        outer.pack(fill="both", expand=True)

        header = ttk.Frame(outer)
        header.pack(fill="x")
        ttk.Label(header, text="XSIGHT Backend Server",
                  style="Header.TLabel").pack(side="left")

        # Status banner
        banner = tk.Frame(outer, bg="#182130", bd=0, highlightthickness=1,
                          highlightbackground="#2a3a55")
        banner.pack(fill="x", pady=(10, 12))
        inner = tk.Frame(banner, bg="#182130")
        inner.pack(pady=12, padx=16, fill="x")

        self.dot = tk.Canvas(inner, width=22, height=22, bg="#182130",
                             highlightthickness=0)
        self.dot_oval = self.dot.create_oval(3, 3, 19, 19, fill="#5b6675",
                                             outline="")
        self.dot.pack(side="left")
        self.status_lbl = tk.Label(
            inner, text="STARTING", font=("Segoe UI", 16, "bold"),
            fg="#c9d4e3", bg="#182130")
        self.status_lbl.pack(side="left", padx=(10, 18))
        self.ping_lbl = tk.Label(inner, text="", font=("Consolas", 11),
                                 fg="#8fa3bd", bg="#182130")
        self.ping_lbl.pack(side="left")

        # Info grid
        grid = ttk.Frame(outer)
        grid.pack(fill="x")
        grid.columnconfigure(1, weight=1)
        rows = [
            ("Server folder", "val_folder"),
            ("Python", "val_python"),
            ("Local IP", "val_ip"),
            ("Port", "val_port"),
            ("Kiosk URL (LAN)", "val_url"),
            ("API docs", "val_docs"),
        ]
        self.vars: dict[str, tk.StringVar] = {}
        for i, (label, key) in enumerate(rows):
            ttk.Label(grid, text=label + ":").grid(
                row=i, column=0, sticky="w", pady=2, padx=(0, 12))
            var = tk.StringVar(value="-")
            self.vars[key] = var
            lbl = ttk.Label(grid, textvariable=var, style="Value.TLabel")
            lbl.grid(row=i, column=1, sticky="w", pady=2)
            if key in ("val_url", "val_docs"):
                lbl.configure(cursor="hand2", foreground="#4fc3f7")
                url_key = key
                lbl.bind("<Button-1>", lambda _e, k=url_key: self._open_link(k))

        self.vars["val_folder"].set(str(self.server_dir) if self.server_dir
                                    else "NOT FOUND")
        self.vars["val_python"].set(self.python_display)
        self.vars["val_ip"].set(self.lan_ip)
        self.vars["val_port"].set(str(self.port))
        self.vars["val_url"].set(f"http://{self.lan_ip}:{self.port}")
        self.vars["val_docs"].set(f"http://127.0.0.1:{self.port}/docs")

        # Buttons
        btns = ttk.Frame(outer)
        btns.pack(fill="x", pady=12)
        self.btn_start = ttk.Button(btns, text="Start", command=self.start_server,
                                    state="disabled")
        self.btn_start.pack(side="left")
        self.btn_stop = ttk.Button(btns, text="Stop", command=self.stop_server,
                                   state="disabled")
        self.btn_stop.pack(side="left", padx=6)
        self.btn_restart = ttk.Button(btns, text="Restart",
                                      command=self.restart_server,
                                      state="disabled")
        self.btn_restart.pack(side="left")
        ttk.Button(btns, text="Open API Docs",
                   command=lambda: webbrowser.open(
                       f"http://127.0.0.1:{self.port}/docs")).pack(side="left",
                                                                   padx=(20, 6))
        if IS_WINDOWS:
            ttk.Button(btns, text="Allow LAN Access (firewall)",
                       command=self.open_firewall).pack(side="left")

        # Log console
        log_frame = tk.Frame(outer, bg="#0b0f16", bd=0,
                             highlightthickness=1,
                             highlightbackground="#26334a")
        log_frame.pack(fill="both", expand=True)
        self.log_box = scrolledtext.ScrolledText(
            log_frame, bg="#0b0f16", fg="#b9e28c", insertbackground="#b9e28c",
            font=("Consolas", 9), state="disabled", wrap="word", bd=8)
        self.log_box.pack(fill="both", expand=True)

        foot = ttk.Frame(outer)
        foot.pack(fill="x", pady=(6, 0))
        ttk.Label(foot, text="AI-assisted screening tool - not a medical "
                  "device. For clinical review only.",
                  foreground="#5b6675").pack(side="left")

        mono = tkfont.nametofont("TkFixedFont")
        mono.configure(family="Consolas")
        self.log_box.configure(font=mono)

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    # ---------------- status ----------------

    def _set_status(self, kind: str, text: str, ping_text: str = "") -> None:
        colors = {
            "ok": "#37d67a", "down": "#ff5252", "warn": "#ffb300",
            "idle": "#5b6675", "error": "#ff5252",
        }
        self.dot.itemconfig(self.dot_oval, fill=colors.get(kind, "#5b6675"))
        fg = {"ok": "#37d67a", "down": "#ff5252", "warn": "#ffb300",
              "error": "#ff5252"}.get(kind, "#c9d4e3")
        self.status_lbl.config(text=text, fg=fg)
        self.ping_lbl.config(text=ping_text)

    def _open_link(self, key: str) -> None:
        value = self.vars[key].get()
        if value.startswith("http"):
            webbrowser.open(value)

    # ---------------- process control ----------------

    def start_server(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            return
        if self.server_dir is None or self.python_argv is None:
            return
        cmd = [*self.python_argv, "main.py"]
        try:
            self.proc = subprocess.Popen(
                cmd, cwd=str(self.server_dir),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace",
                bufsize=1, creationflags=CREATE_NO_WINDOW,
                env={**os.environ, "PYTHONUNBUFFERED": "1"},
            )
        except OSError as exc:
            self.log(f"[!] Failed to launch python: {exc}\n")
            self._set_status("error", "LAUNCH FAILED")
            return
        self.log(f"[>] $ {' '.join(cmd)}   (cwd={self.server_dir})\n")
        self._set_status("warn", "STARTING...")
        threading.Thread(target=self._read_output, daemon=True).start()
        self._refresh_buttons()

    def stop_server(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self._kill_tree(self.proc.pid)
            self.log("[x] Stop requested - killed process tree\n")
        self.proc = None
        self._set_status("idle", "STOPPED")
        self._refresh_buttons()

    def restart_server(self) -> None:
        self.stop_server()
        self.root.after(600, self.start_server)

    @staticmethod
    def _kill_tree(pid: int) -> None:
        if IS_WINDOWS:
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                capture_output=True, creationflags=CREATE_NO_WINDOW,
            )
        else:
            import signal

            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def _read_output(self) -> None:
        proc = self.proc
        if proc is None or proc.stdout is None:
            return
        try:
            for line in proc.stdout:
                line = ANSI_RE.sub("", line.rstrip("\r\n"))
                if line:
                    self.log_q.put(line + "\n")
        finally:
            code = proc.wait()
            self.log_q.put(f"\n[!] Server exited with code {code}\n")

    def _refresh_buttons(self) -> None:
        running = self.proc is not None and self.proc.poll() is None
        ready = self.server_dir is not None and self.python_argv is not None
        self.btn_start.config(state="disabled" if (running or not ready) else "normal")
        self.btn_stop.config(state="normal" if running else "disabled")
        self.btn_restart.config(state="normal" if running else "disabled")

    # ---------------- logging ----------------

    def log(self, text: str) -> None:
        self.log_box.configure(state="normal")
        self.log_box.insert("end", text)
        if float(self.log_box.index("end-1c").split(".")[0]) > self.LOG_MAX_LINES:
            self.log_box.delete("1.0", f"{self.LOG_MAX_LINES // 2}.0")
        self.log_box.see("end")
        self.log_box.configure(state="disabled")

    def _drain_log_queue(self) -> None:
        try:
            while True:
                self.log(self.log_q.get_nowait())
        except queue.Empty:
            pass
        self.root.after(80, self._drain_log_queue)

    # ---------------- health ping ----------------

    def _ping_once(self) -> tuple[bool, int]:
        url = f"http://127.0.0.1:{self.port}/health"
        start = time.perf_counter()
        try:
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=1.5):
                return True, int((time.perf_counter() - start) * 1000)
        except Exception:
            return False, int((time.perf_counter() - start) * 1000)

    def _schedule_ping(self) -> None:
        self.root.after(self.PING_INTERVAL_MS, self._ping_tick)

    def _ping_tick(self) -> None:
        running_here = self.proc is not None and self.proc.poll() is None
        ok, ms = self._ping_once()
        if ok:
            self.last_ok_ping = time.time()
        if running_here:
            if ok:
                self._set_status("ok", "ACTIVE", f"ping OK  {ms} ms  "
                                 f"(127.0.0.1:{self.port}/health)")
            elif self.last_ok_ping is None:
                self._set_status("warn", "STARTING...", "waiting for /health ...")
            else:
                self._set_status("down", "DOWN", f"/health unreachable "
                                 f"({ms} ms)")
        else:
            if ok:
                self._set_status("warn", "IN USE BY OTHER PROCESS",
                                 f"something already answers on port {self.port}")
            else:
                self._set_status("idle", "STOPPED", "")
        self._refresh_buttons()
        self._schedule_ping()

    # ---------------- extras ----------------

    def open_firewall(self) -> None:
        if not IS_WINDOWS:
            return
        ps = (
            "Start-Process cmd -Verb RunAs -Wait -ArgumentList "
            "'/c netsh advfirewall firewall delete rule name=\"XSIGHT Server\" "
            "& netsh advfirewall firewall add rule name=\"XSIGHT Server\" "
            f"dir=in action=allow protocol=TCP localport={self.port} "
            "& pause'"
        )
        subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                       creationflags=CREATE_NO_WINDOW)
        self.log(f"[i] Firewall rule requested for TCP {self.port} "
                 "(approve the UAC prompt)\n")

    def on_close(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self._kill_tree(self.proc.pid)
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    LauncherApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
