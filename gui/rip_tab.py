"""Rip tab — scan disc and rip selected titles using MakeMKV."""

from __future__ import annotations

import queue
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
from config import load_config


def _human_size(size_bytes: int) -> str:
    """Format byte count as a human-readable string."""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


class RipTab(ttk.Frame):
    """Tab for scanning a disc and ripping selected titles."""

    def __init__(self, parent, app):
        super().__init__(parent)
        self.app = app
        self.disc_info: DiscInfo | None = None
        self._check_vars: dict[int, tk.BooleanVar] = {}
        self._msg_queue: queue.Queue = queue.Queue()

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

        self.disc_label = ttk.Label(btn_row, text="No disc scanned")
        self.disc_label.pack(side=tk.LEFT, padx=(15, 0))

        # -- Title list --
        list_frame = ttk.LabelFrame(self, text="Titles")
        list_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)

        columns = ("select", "title", "duration", "size", "chapters")
        self.tree = ttk.Treeview(
            list_frame, columns=columns, show="headings", selectmode="browse"
        )
        self.tree.heading("select", text="✓")
        self.tree.heading("title", text="Title")
        self.tree.heading("duration", text="Duration")
        self.tree.heading("size", text="Size")
        self.tree.heading("chapters", text="Chapters")

        self.tree.column("select", width=40, anchor=tk.CENTER, stretch=False)
        self.tree.column("title", width=300)
        self.tree.column("duration", width=100, anchor=tk.CENTER)
        self.tree.column("size", width=100, anchor=tk.CENTER)
        self.tree.column("chapters", width=80, anchor=tk.CENTER)

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

        # -- Progress section --
        prog_frame = ttk.LabelFrame(self, text="Progress")
        prog_frame.pack(fill=tk.X, padx=10, pady=(5, 10))

        self.progress_var = tk.IntVar(value=0)
        self.progress_bar = ttk.Progressbar(
            prog_frame, variable=self.progress_var, maximum=100
        )
        self.progress_bar.pack(fill=tk.X, padx=10, pady=(5, 0))

        self.progress_label = ttk.Label(prog_frame, text="Idle")
        self.progress_label.pack(padx=10, pady=(0, 5))

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
        # Find the largest title to auto-select it
        largest_id = max(
            (t for t in self.disc_info.titles),
            key=lambda t: t.size_bytes,
            default=None,
        )
        for t in self.disc_info.titles:
            selected = largest_id is not None and t.id == largest_id.id
            var = tk.BooleanVar(value=selected)
            self._check_vars[t.id] = var
            self.tree.insert(
                "",
                tk.END,
                iid=str(t.id),
                values=("☑" if selected else "☐", t.name, t.duration, _human_size(t.size_bytes), t.chapters),
            )
        self.rip_btn.configure(state=tk.NORMAL)

    # ---------------------------------------------------------- scan logic
    def _on_scan(self):
        self.scan_btn.configure(state=tk.DISABLED)
        self.rip_btn.configure(state=tk.DISABLED)
        self.disc_label.configure(text="Scanning…")
        self.progress_label.configure(text="Scanning disc…")
        self.progress_var.set(0)
        self.progress_bar.configure(mode="indeterminate")
        self.progress_bar.start(15)

        threading.Thread(target=self._scan_worker, daemon=True).start()
        self.after(100, self._poll_queue)

    def _scan_worker(self):
        try:
            disc = scan_disc()
            self._msg_queue.put(("scan_ok", disc))
        except DiscNotFoundError as exc:
            self._msg_queue.put(("scan_err", f"No disc found:\n{exc}"))
        except MakeMKVNotFoundError as exc:
            self._msg_queue.put(("scan_err", f"MakeMKV not found:\n{exc}"))
        except MakeMKVError as exc:
            self._msg_queue.put(("scan_err", f"Scan error:\n{exc}"))
        except Exception as exc:
            self._msg_queue.put(("scan_err", f"Unexpected error:\n{exc}"))

    # ----------------------------------------------------------- rip logic
    def _on_rip(self):
        selected = [tid for tid, var in self._check_vars.items() if var.get()]
        if not selected:
            messagebox.showwarning("Nothing selected", "Select at least one title to rip.")
            return

        config = load_config()
        output_dir = config.get("output_dir", "")
        if not output_dir:
            messagebox.showerror("Error", "Output directory not configured. Check Settings tab.")
            return

        self.scan_btn.configure(state=tk.DISABLED)
        self.rip_btn.configure(state=tk.DISABLED)
        self.progress_bar.configure(mode="determinate")
        self.progress_var.set(0)
        self.progress_label.configure(text="Starting rip…")

        threading.Thread(
            target=self._rip_worker, args=(selected, output_dir), daemon=True
        ).start()
        self.after(100, self._poll_queue)

    def _rip_worker(self, title_ids: list[int], output_dir: str):
        total = len(title_ids)
        ripped_files: list[str] = []
        for idx, tid in enumerate(title_ids, 1):

            def _progress_cb(percent, msg, _idx=idx, _total=total):
                overall = int((((_idx - 1) / _total) + (max(percent, 0) / 100 / _total)) * 100)
                label = f"[{_idx}/{_total}] {msg}"
                self._msg_queue.put(("rip_progress", (overall, label)))

            try:
                path = rip_title(tid, output_dir, progress_callback=_progress_cb)
                ripped_files.append(path)
            except (RipError, MakeMKVError) as exc:
                self._msg_queue.put(("rip_err", f"Failed to rip title {tid}:\n{exc}"))
                return
            except Exception as exc:
                self._msg_queue.put(("rip_err", f"Unexpected error ripping title {tid}:\n{exc}"))
                return

        self._msg_queue.put(("rip_done", ripped_files))

    # --------------------------------------------------- queue poller
    def _poll_queue(self):
        try:
            while True:
                msg_type, payload = self._msg_queue.get_nowait()

                if msg_type == "scan_ok":
                    self.disc_info = payload
                    disc = self.disc_info
                    self.disc_label.configure(
                        text=f"{disc.name}  ({disc.type.upper()}, {len(disc.titles)} titles)"
                    )
                    self._populate_titles()
                    self.progress_bar.stop()
                    self.progress_bar.configure(mode="determinate")
                    self.progress_var.set(0)
                    self.progress_label.configure(text="Scan complete")
                    self.scan_btn.configure(state=tk.NORMAL)
                    self.app.set_status(f"Scanned: {disc.name}")

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

                elif msg_type == "rip_err":
                    self.progress_label.configure(text="Rip failed")
                    self.scan_btn.configure(state=tk.NORMAL)
                    self.rip_btn.configure(state=tk.NORMAL)
                    messagebox.showerror("Rip Error", str(payload))

                elif msg_type == "rip_done":
                    ripped = payload
                    self.progress_var.set(100)
                    self.progress_label.configure(text="Rip complete")
                    self.scan_btn.configure(state=tk.NORMAL)
                    self.rip_btn.configure(state=tk.NORMAL)
                    self.app.set_status(f"Ripped {len(ripped)} title(s)")
                    # Pass the last ripped file to the organize tab
                    if ripped:
                        disc_name = self.disc_info.name if self.disc_info else ""
                        self.app.on_rip_complete(ripped[-1], disc_name)
                    messagebox.showinfo(
                        "Rip Complete",
                        f"Successfully ripped {len(ripped)} title(s).",
                    )

        except queue.Empty:
            pass

        # Keep polling while buttons are disabled (operation in progress)
        if str(self.scan_btn.cget("state")) == "disabled":
            self.after(100, self._poll_queue)
