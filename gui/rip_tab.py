"""Rip tab — scan disc and rip selected titles using MakeMKV."""

from __future__ import annotations

import os
import queue
import subprocess
import threading
import tkinter as tk
from tkinter import ttk, messagebox

from core.makemkv import (
    scan_disc,
    rip_title,
    MakeMKVError,
    DiscNotFoundError,
    MakeMKVNotFoundError,
    RipError,
)
from core.disc import DiscInfo
from core.metadata import search_media, clean_disc_name
from core.organizer import clean_filename
from config import load_config


def _human_size(size_bytes: int) -> str:
    """Format byte count as a human-readable string."""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


def _duration_to_secs(duration: str) -> int:
    """Convert a duration string like '1:52:30' to total seconds."""
    parts = duration.split(":")
    try:
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
        elif len(parts) == 2:
            return int(parts[0]) * 60 + int(parts[1])
        return int(parts[0])
    except ValueError:
        return 0


def _resolution_label(resolution: str) -> str:
    """Convert resolution string like '1920x1080' to a friendly label."""
    if not resolution:
        return ""
    try:
        w, h = resolution.lower().split("x")
        height = int(h)
    except (ValueError, AttributeError):
        return resolution
    if height >= 2160:
        return "4K UHD"
    elif height >= 1080:
        return "1080p"
    elif height >= 720:
        return "720p"
    elif height >= 576:
        return "576p"
    elif height >= 480:
        return "480p"
    return f"{height}p"


class RipTab(ttk.Frame):
    """Tab for scanning a disc and ripping selected titles."""

    def __init__(self, parent, app):
        super().__init__(parent)
        self.app = app
        self.disc_info: DiscInfo | None = None
        self._check_vars: dict[int, tk.BooleanVar] = {}
        self._msg_queue: queue.Queue = queue.Queue()
        self._proc: subprocess.Popen | None = None
        self._aborted = False
        self._tmdb_title: str = ""  # cleaned title from TMDb lookup
        self._full_auto = False

        self._build_ui()

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        # -- Scan section --
        scan_frame = ttk.LabelFrame(self, text="Disc Scanner")
        scan_frame.pack(fill=tk.X, padx=10, pady=(10, 5))

        btn_row = ttk.Frame(scan_frame)
        btn_row.pack(fill=tk.X, padx=10, pady=5)

        self.scan_btn = ttk.Button(btn_row, text="Scan Disc", command=self._on_scan)
        self.scan_btn.pack(side=tk.LEFT)

        ttk.Label(btn_row, text="Min duration (s):").pack(side=tk.LEFT, padx=(15, 0))
        config = load_config()
        self.min_duration_var = tk.IntVar(value=config.get("min_duration", 120))
        self.min_duration_spin = ttk.Spinbox(
            btn_row, from_=0, to=9999, width=6,
            textvariable=self.min_duration_var
        )
        self.min_duration_spin.pack(side=tk.LEFT, padx=(5, 0))

        self.disc_label = ttk.Label(btn_row, text="No disc scanned")
        self.disc_label.pack(side=tk.LEFT, padx=(15, 0))

        # -- Title list --
        list_frame = ttk.LabelFrame(self, text="Titles")
        list_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)

        columns = ("select", "title", "resolution", "duration", "size", "chapters")
        self.tree = ttk.Treeview(
            list_frame, columns=columns, show="headings", selectmode="browse"
        )
        self.tree.heading("select", text="✓")
        self.tree.heading("title", text="Title")
        self.tree.heading("resolution", text="Resolution")
        self.tree.heading("duration", text="Duration")
        self.tree.heading("size", text="Size")
        self.tree.heading("chapters", text="Chapters")

        self.tree.column("select", width=40, anchor=tk.CENTER, stretch=False)
        self.tree.column("title", width=250)
        self.tree.column("resolution", width=90, anchor=tk.CENTER)
        self.tree.column("duration", width=90, anchor=tk.CENTER)
        self.tree.column("size", width=90, anchor=tk.CENTER)
        self.tree.column("chapters", width=70, anchor=tk.CENTER)

        scrollbar = ttk.Scrollbar(list_frame, orient=tk.VERTICAL, command=self.tree.yview)
        self.tree.configure(yscrollcommand=scrollbar.set)
        self.tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(10, 0), pady=5)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y, padx=(0, 10), pady=5)

        self.tree.bind("<ButtonRelease-1>", self._on_tree_click)

        # -- Select / Deselect buttons --
        sel_frame = ttk.Frame(self)
        sel_frame.pack(fill=tk.X, padx=10)

        ttk.Button(sel_frame, text="Select All", command=self._select_all).pack(
            side=tk.LEFT, padx=(0, 5)
        )
        ttk.Button(sel_frame, text="Deselect All", command=self._deselect_all).pack(
            side=tk.LEFT
        )

        self.rip_btn = ttk.Button(
            sel_frame, text="Rip Selected", command=self._on_rip, state=tk.DISABLED
        )
        self.rip_btn.pack(side=tk.RIGHT)

        self.full_auto_btn = ttk.Button(
            sel_frame, text="⚡ Full Auto", command=self._on_full_auto, state=tk.DISABLED
        )
        self.full_auto_btn.pack(side=tk.RIGHT, padx=(0, 5))

        self.abort_btn = ttk.Button(
            sel_frame, text="Abort", command=self._on_abort, state=tk.DISABLED
        )
        self.abort_btn.pack(side=tk.RIGHT, padx=(0, 5))

        self.auto_eject_var = tk.BooleanVar(value=config.get("auto_eject", True))
        ttk.Checkbutton(
            sel_frame, text="Eject disc after rip", variable=self.auto_eject_var
        ).pack(side=tk.RIGHT, padx=(0, 15))

        # -- Progress section --
        prog_frame = ttk.LabelFrame(self, text="Progress")
        prog_frame.pack(fill=tk.X, padx=10, pady=(5, 0))

        self.progress_var = tk.IntVar(value=0)
        self.progress_bar = ttk.Progressbar(
            prog_frame, variable=self.progress_var, maximum=100
        )
        self.progress_bar.pack(fill=tk.X, padx=10, pady=(5, 0))

        self.progress_label = ttk.Label(prog_frame, text="Idle")
        self.progress_label.pack(padx=10, pady=(0, 5))

        # -- Log output --
        log_frame = ttk.LabelFrame(self, text="Log")
        log_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=(5, 10))

        self.log_text = tk.Text(log_frame, height=6, wrap=tk.WORD, state=tk.DISABLED)
        log_scroll = ttk.Scrollbar(log_frame, orient=tk.VERTICAL, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=log_scroll.set)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(10, 0), pady=5)
        log_scroll.pack(side=tk.RIGHT, fill=tk.Y, padx=(0, 10), pady=5)

    # --------------------------------------------------------- tree helpers
    def _on_tree_click(self, event):
        """Toggle check mark when the select column is clicked."""
        region = self.tree.identify_region(event.x, event.y)
        if region != "cell":
            return
        col = self.tree.identify_column(event.x)
        if col != "#1":  # select column
            return
        item = self.tree.identify_row(event.y)
        if not item:
            return
        tid = int(item)
        var = self._check_vars.get(tid)
        if var is None:
            return
        var.set(not var.get())
        mark = "☑" if var.get() else "☐"
        self.tree.set(item, "select", mark)

    def _select_all(self):
        for tid, var in self._check_vars.items():
            var.set(True)
            self.tree.set(str(tid), "select", "☑")

    def _deselect_all(self):
        for tid, var in self._check_vars.items():
            var.set(False)
            self.tree.set(str(tid), "select", "☐")

    def _populate_titles(self):
        self.tree.delete(*self.tree.get_children())
        self._check_vars.clear()
        if not self.disc_info:
            return

        min_secs = self.min_duration_var.get()

        # Filter titles by minimum duration
        filtered = [t for t in self.disc_info.titles if _duration_to_secs(t.duration) >= min_secs]

        # Find the largest title to auto-select it
        largest_id = max(
            filtered,
            key=lambda t: t.size_bytes,
            default=None,
        )
        for t in filtered:
            selected = largest_id is not None and t.id == largest_id.id
            var = tk.BooleanVar(value=selected)
            self._check_vars[t.id] = var
            res_label = _resolution_label(t.resolution)
            self.tree.insert(
                "",
                tk.END,
                iid=str(t.id),
                values=("☑" if selected else "☐", t.name, res_label, t.duration, _human_size(t.size_bytes), t.chapters),
            )
        self.rip_btn.configure(state=tk.NORMAL)
        self.full_auto_btn.configure(state=tk.NORMAL)

    # ---------------------------------------------------------- scan logic
    def _on_scan(self):
        self.scan_btn.configure(state=tk.DISABLED)
        self.rip_btn.configure(state=tk.DISABLED)
        self.disc_label.configure(text="Scanning…")
        self.progress_label.configure(text="Scanning disc…")
        self.progress_var.set(0)
        self.progress_bar.configure(mode="indeterminate")
        self.progress_bar.start(15)

        self.log_text.configure(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state=tk.DISABLED)

        threading.Thread(target=self._scan_worker, daemon=True).start()
        self.after(100, self._poll_queue)

    def _scan_worker(self):
        def _log_cb(line):
            self._msg_queue.put(("scan_log", line))

        try:
            disc = scan_disc(log_callback=_log_cb)
            # Auto-lookup TMDb to get the proper title
            tmdb_title = ""
            if disc.name:
                try:
                    results = search_media(disc.name)
                    if results:
                        tmdb_title = results[0].title
                except Exception:
                    pass
            self._msg_queue.put(("scan_ok", (disc, tmdb_title)))
        except DiscNotFoundError as exc:
            self._msg_queue.put(("scan_err", f"No disc found:\n{exc}"))
        except MakeMKVNotFoundError as exc:
            self._msg_queue.put(("scan_err", f"MakeMKV not found:\n{exc}"))
        except MakeMKVError as exc:
            self._msg_queue.put(("scan_err", f"Scan error:\n{exc}"))
        except Exception as exc:
            self._msg_queue.put(("scan_err", f"Unexpected error:\n{exc}"))

    # ----------------------------------------------------------- rip logic
    def _on_full_auto(self):
        """Rip selected titles then auto-run encode → organize → tMM."""
        self._full_auto = True
        self._on_rip()

    def _on_rip(self):
        selected = [tid for tid, var in self._check_vars.items() if var.get()]
        if not selected:
            messagebox.showwarning("Nothing selected", "Select at least one title to rip.")
            self._full_auto = False
            return

        config = load_config()
        output_dir = config.get("output_dir", "")
        if not output_dir:
            messagebox.showerror("Error", "Output directory not configured. Check Settings tab.")
            self._full_auto = False
            return

        # Create a subfolder named after the TMDb title (or disc name as fallback)
        folder_name = self._tmdb_title or (self.disc_info.name if self.disc_info else "")
        if folder_name:
            output_dir = os.path.join(output_dir, clean_filename(folder_name))

        self.scan_btn.configure(state=tk.DISABLED)
        self.rip_btn.configure(state=tk.DISABLED)
        self.full_auto_btn.configure(state=tk.DISABLED)
        self.abort_btn.configure(state=tk.NORMAL)
        self._aborted = False
        self.progress_bar.configure(mode="determinate")
        self.progress_var.set(0)
        self.progress_label.configure(text="Starting rip…")
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state=tk.DISABLED)

        threading.Thread(
            target=self._rip_worker, args=(selected, output_dir), daemon=True
        ).start()
        self.after(100, self._poll_queue)

    def _on_abort(self):
        """Kill the running MakeMKV process."""
        self._aborted = True
        if self._proc and self._proc.poll() is None:
            self._proc.kill()
        self.abort_btn.configure(state=tk.DISABLED)
        self.progress_label.configure(text="Aborting…")

    def _rip_worker(self, title_ids: list[int], output_dir: str):
        import time
        total = len(title_ids)
        ripped_files: list[str] = []
        for idx, tid in enumerate(title_ids, 1):
            if self._aborted:
                self._msg_queue.put(("rip_err", "Rip aborted by user"))
                return

            # Get expected size for this title
            expected_bytes = 0
            if self.disc_info:
                for t in self.disc_info.titles:
                    if t.id == tid:
                        expected_bytes = t.size_bytes
                        break

            # Monitor file size in a separate thread for progress
            stop_monitor = threading.Event()

            def _size_monitor(_idx=idx, _total=total):
                start_time = time.monotonic()
                while not stop_monitor.is_set():
                    # Find the newest .mkv file being written
                    try:
                        mkv_files = [
                            os.path.join(output_dir, f)
                            for f in os.listdir(output_dir) if f.endswith(".mkv")
                        ]
                    except FileNotFoundError:
                        stop_monitor.wait(1)
                        continue
                    if not mkv_files:
                        stop_monitor.wait(1)
                        continue

                    newest = max(mkv_files, key=lambda f: os.path.getmtime(f))
                    try:
                        current_size = os.path.getsize(newest)
                    except OSError:
                        stop_monitor.wait(1)
                        continue

                    if expected_bytes > 0:
                        percent = min(int(current_size / expected_bytes * 100), 99)
                        elapsed = time.monotonic() - start_time
                        if percent > 0:
                            remaining = elapsed / (percent / 100) - elapsed
                            mins, secs = divmod(int(remaining), 60)
                            hrs, mins = divmod(mins, 60)
                            eta = f"ETA {hrs}h{mins:02d}m" if hrs else f"ETA {mins}m{secs:02d}s"
                        else:
                            eta = "ETA calculating..."
                        written = _human_size(current_size)
                        total_str = _human_size(expected_bytes)
                        overall = int((((_idx - 1) / _total) + (percent / 100 / _total)) * 100)
                        label = f"[{_idx}/{_total}] {written} / {total_str} ({percent}%) — {eta}"
                        self._msg_queue.put(("rip_progress", (overall, label)))

                    stop_monitor.wait(2)

            monitor_thread = threading.Thread(target=_size_monitor, daemon=True)
            monitor_thread.start()

            # Skip scan/structural lines, only show rip progress and messages
            _SCAN_PREFIXES = ("DRV:", "TINFO:", "CINFO:", "SINFO:", "PRGV:", "PRGC:")

            def _log_cb(line):
                if line.startswith(_SCAN_PREFIXES):
                    return
                if line.startswith("MSG:3025") or line.startswith("MSG:3307"):
                    return
                self._msg_queue.put(("rip_log", line))

            def _proc_cb(proc):
                self._proc = proc

            try:
                path = rip_title(
                    tid, output_dir,
                    log_callback=_log_cb,
                    proc_callback=_proc_cb,
                )
                stop_monitor.set()
                ripped_files.append(path)
            except (RipError, MakeMKVError) as exc:
                stop_monitor.set()
                if self._aborted:
                    self._msg_queue.put(("rip_err", "Rip aborted by user"))
                else:
                    self._msg_queue.put(("rip_err", f"Failed to rip title {tid}:\n{exc}"))
                return
            except Exception as exc:
                stop_monitor.set()
                if self._aborted:
                    self._msg_queue.put(("rip_err", "Rip aborted by user"))
                else:
                    self._msg_queue.put(("rip_err", f"Unexpected error ripping title {tid}:\n{exc}"))
                return

        self._msg_queue.put(("rip_done", ripped_files))

    # --------------------------------------------------- queue poller
    def _poll_queue(self):
        try:
            while True:
                msg_type, payload = self._msg_queue.get_nowait()

                if msg_type == "scan_log":
                    self.log_text.configure(state=tk.NORMAL)
                    self.log_text.insert(tk.END, payload + "\n")
                    self.log_text.see(tk.END)
                    self.log_text.configure(state=tk.DISABLED)

                elif msg_type == "scan_ok":
                    disc, tmdb_title = payload
                    self.disc_info = disc
                    self._tmdb_title = tmdb_title
                    display_name = tmdb_title or disc.name
                    self.disc_label.configure(
                        text=f"{display_name}  ({disc.type.upper()}, {len(disc.titles)} titles)"
                    )
                    self._populate_titles()
                    self.progress_bar.stop()
                    self.progress_bar.configure(mode="determinate")
                    self.progress_var.set(0)
                    self.progress_label.configure(text="Scan complete")
                    self.scan_btn.configure(state=tk.NORMAL)
                    self.app.set_status(f"Scanned: {display_name}")

                elif msg_type == "scan_err":
                    self.progress_bar.stop()
                    self.progress_bar.configure(mode="determinate")
                    self.progress_var.set(0)
                    self.progress_label.configure(text="Scan failed")
                    self.disc_label.configure(text="No disc scanned")
                    self.scan_btn.configure(state=tk.NORMAL)
                    messagebox.showerror("Scan Error", str(payload))

                elif msg_type == "rip_progress":
                    percent, label = payload
                    self.progress_var.set(percent)
                    self.progress_label.configure(text=label)

                elif msg_type == "rip_log":
                    self.log_text.configure(state=tk.NORMAL)
                    self.log_text.insert(tk.END, payload + "\n")
                    self.log_text.see(tk.END)
                    self.log_text.configure(state=tk.DISABLED)

                elif msg_type == "rip_err":
                    self.progress_label.configure(text="Rip failed")
                    self.scan_btn.configure(state=tk.NORMAL)
                    self.rip_btn.configure(state=tk.NORMAL)
                    self.full_auto_btn.configure(state=tk.NORMAL)
                    self.abort_btn.configure(state=tk.DISABLED)
                    self._full_auto = False
                    messagebox.showerror("Rip Error", str(payload))

                elif msg_type == "rip_done":
                    ripped = payload
                    self.progress_var.set(100)
                    self.progress_label.configure(text="Rip complete")
                    self.scan_btn.configure(state=tk.NORMAL)
                    self.rip_btn.configure(state=tk.NORMAL)
                    self.full_auto_btn.configure(state=tk.NORMAL)
                    self.abort_btn.configure(state=tk.DISABLED)
                    self.app.set_status(f"Ripped {len(ripped)} title(s)")
                    # Auto-eject disc
                    if self.auto_eject_var.get():
                        self._eject_disc()
                    # Pass the last ripped file to the encode tab
                    auto = self._full_auto
                    self._full_auto = False
                    if ripped:
                        disc_name = self._tmdb_title or (self.disc_info.name if self.disc_info else "")
                        # Get resolution from the largest selected title
                        resolution = ""
                        if self.disc_info:
                            selected_ids = [tid for tid, var in self._check_vars.items() if var.get()]
                            for t in self.disc_info.titles:
                                if t.id in selected_ids and t.resolution:
                                    resolution = t.resolution
                                    break
                        self.app.on_rip_complete(ripped[-1], disc_name, auto_start=auto, resolution=resolution)
                    if auto:
                        # Reset for next disc
                        self.disc_info = None
                        self._tmdb_title = ""
                        self.disc_label.configure(text="Insert next disc and scan")
                        self.tree.delete(*self.tree.get_children())
                        self._check_vars.clear()
                    else:
                        messagebox.showinfo(
                            "Rip Complete",
                            f"Successfully ripped {len(ripped)} title(s).",
                        )

        except queue.Empty:
            pass

        # Keep polling while buttons are disabled (operation in progress)
        if str(self.scan_btn.cget("state")) == "disabled":
            self.after(100, self._poll_queue)

    def _eject_disc(self):
        """Eject the disc drive using macOS drutil."""
        try:
            subprocess.run(["drutil", "eject"], capture_output=True, timeout=10)
            self.app.set_status("Disc ejected")
        except Exception:
            pass  # non-critical, don't bother the user
