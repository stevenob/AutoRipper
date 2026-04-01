"""tinyMediaManager tab — scrape metadata, rename, and download subtitles."""

from __future__ import annotations

import queue
import subprocess
import threading
import tkinter as tk
from tkinter import ttk, messagebox

from core.tmm import (
    scrape_and_rename,
    download_subtitles,
    TmmError,
    TmmNotFoundError,
)


class TmmTab(ttk.Frame):
    """Tab for running tinyMediaManager CLI actions."""

    def __init__(self, parent, app):
        super().__init__(parent)
        self.app = app
        self._msg_queue: queue.Queue = queue.Queue()
        self._proc: subprocess.Popen | None = None
        self._aborted = False

        self._build_ui()

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        # -- Media type --
        type_frame = ttk.LabelFrame(self, text="Media Type")
        type_frame.pack(fill=tk.X, padx=10, pady=(10, 5))

        type_row = ttk.Frame(type_frame)
        type_row.pack(fill=tk.X, padx=10, pady=5)

        from config import load_config as _load_cfg
        _cfg = _load_cfg()
        self.media_type_var = tk.StringVar(value=_cfg.get("default_media_type", "movie"))
        ttk.Radiobutton(
            type_row, text="Movie", variable=self.media_type_var, value="movie",
        ).pack(side=tk.LEFT, padx=(0, 10))
        ttk.Radiobutton(
            type_row, text="TV Show", variable=self.media_type_var, value="tvshow",
        ).pack(side=tk.LEFT)

        # -- Actions --
        action_frame = ttk.LabelFrame(self, text="Actions")
        action_frame.pack(fill=tk.X, padx=10, pady=5)

        btn_row = ttk.Frame(action_frame)
        btn_row.pack(fill=tk.X, padx=10, pady=5)

        self.scrape_btn = ttk.Button(
            btn_row, text="Scrape & Rename", command=self._on_scrape,
        )
        self.scrape_btn.pack(side=tk.LEFT, padx=(0, 5))

        self.subs_btn = ttk.Button(
            btn_row, text="Download Subtitles", command=self._on_subs,
        )
        self.subs_btn.pack(side=tk.LEFT, padx=(0, 5))

        self.abort_btn = ttk.Button(
            btn_row, text="Abort", command=self._on_abort, state=tk.DISABLED,
        )
        self.abort_btn.pack(side=tk.LEFT)

        # -- Progress --
        progress_frame = ttk.LabelFrame(self, text="Progress")
        progress_frame.pack(fill=tk.X, padx=10, pady=5)

        self.progress_bar = ttk.Progressbar(
            progress_frame, mode="indeterminate",
        )
        self.progress_bar.pack(fill=tk.X, padx=10, pady=(5, 0))

        self.status_label = ttk.Label(progress_frame, text="Idle")
        self.status_label.pack(padx=10, pady=(0, 5))

        # -- Log --
        log_frame = ttk.LabelFrame(self, text="Log")
        log_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=(0, 10))

        self.log_text = tk.Text(log_frame, height=12, wrap=tk.WORD, state=tk.DISABLED)
        log_scroll = ttk.Scrollbar(
            log_frame, orient=tk.VERTICAL, command=self.log_text.yview,
        )
        self.log_text.configure(yscrollcommand=log_scroll.set)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(10, 0), pady=5)
        log_scroll.pack(side=tk.RIGHT, fill=tk.Y, padx=(0, 10), pady=5)

    # --------------------------------------------------------- actions
    def _on_scrape(self):
        self._run_action("scrape")

    def _on_subs(self):
        self._run_action("subs")

    def auto_scrape(self):
        """Auto-start scrape & rename (called by app after organize)."""
        self.after(500, self._on_scrape)

    def _run_action(self, action: str):
        """Start a tMM action in a background thread."""
        media_type = self.media_type_var.get()

        self.scrape_btn.configure(state=tk.DISABLED)
        self.subs_btn.configure(state=tk.DISABLED)
        self.abort_btn.configure(state=tk.NORMAL)
        self._aborted = False

        # Clear log
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state=tk.DISABLED)

        self.progress_bar.start(15)
        label = "Scraping & renaming…" if action == "scrape" else "Downloading subtitles…"
        self.status_label.configure(text=label)
        self.app.set_status(label)

        threading.Thread(
            target=self._tmm_worker, args=(action, media_type), daemon=True,
        ).start()
        self.after(100, self._poll_queue)

    def _on_abort(self):
        """Kill the running tMM process."""
        self._aborted = True
        if self._proc and self._proc.poll() is None:
            self._proc.kill()
        self.abort_btn.configure(state=tk.DISABLED)
        self.status_label.configure(text="Aborting…")

    # --------------------------------------------------------- worker
    def _tmm_worker(self, action: str, media_type: str):
        def _log_cb(line: str):
            self._msg_queue.put(("tmm_log", line))

        def _proc_cb(proc):
            self._proc = proc

        try:
            if action == "scrape":
                ok = scrape_and_rename(media_type, log_callback=_log_cb, proc_callback=_proc_cb)
            else:
                ok = download_subtitles(media_type, log_callback=_log_cb, proc_callback=_proc_cb)

            if ok:
                self._msg_queue.put(("tmm_done", action))
            else:
                if self._aborted:
                    self._msg_queue.put(("tmm_err", "Operation aborted by user"))
                else:
                    self._msg_queue.put(("tmm_err", "tMM exited with errors"))
        except (TmmNotFoundError, TmmError) as exc:
            if self._aborted:
                self._msg_queue.put(("tmm_err", "Operation aborted by user"))
            else:
                self._msg_queue.put(("tmm_err", str(exc)))
        except Exception as exc:
            self._msg_queue.put(("tmm_err", f"Unexpected error: {exc}"))

    # --------------------------------------------------- queue poller
    def _poll_queue(self):
        try:
            while True:
                msg_type, payload = self._msg_queue.get_nowait()

                if msg_type == "tmm_log":
                    self.log_text.configure(state=tk.NORMAL)
                    self.log_text.insert(tk.END, payload + "\n")
                    self.log_text.see(tk.END)
                    self.log_text.configure(state=tk.DISABLED)

                elif msg_type == "tmm_done":
                    self.progress_bar.stop()
                    action = payload
                    msg = (
                        "Scrape & rename complete"
                        if action == "scrape"
                        else "Subtitle download complete"
                    )
                    self.status_label.configure(text=msg)
                    self.scrape_btn.configure(state=tk.NORMAL)
                    self.subs_btn.configure(state=tk.NORMAL)
                    self.abort_btn.configure(state=tk.DISABLED)
                    self.app.set_status(msg)
                    messagebox.showinfo("tinyMediaManager", msg)

                elif msg_type == "tmm_err":
                    self.progress_bar.stop()
                    self.status_label.configure(text="Failed")
                    self.scrape_btn.configure(state=tk.NORMAL)
                    self.subs_btn.configure(state=tk.NORMAL)
                    self.abort_btn.configure(state=tk.DISABLED)
                    self.app.set_status("tMM operation failed")
                    messagebox.showerror("tinyMediaManager Error", str(payload))

        except queue.Empty:
            pass

        # Keep polling while an action is running
        if str(self.scrape_btn.cget("state")) == "disabled":
            self.after(100, self._poll_queue)
