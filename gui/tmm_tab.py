"""tinyMediaManager tab — scrape metadata, rename, and download subtitles."""

from __future__ import annotations

import queue
import subprocess
import threading
import tkinter as tk
from tkinter import messagebox

import customtkinter as ctk

from core.tmm import (
    scrape_and_rename,
    download_subtitles,
    TmmError,
    TmmNotFoundError,
)


class TmmTab(ctk.CTkFrame):
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
        ctk.CTkLabel(self, text="Media Type", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(10, 0)
        )
        type_frame = ctk.CTkFrame(self)
        type_frame.pack(fill="x", padx=10, pady=(5, 5))

        type_row = ctk.CTkFrame(type_frame, fg_color="transparent")
        type_row.pack(fill="x", padx=10, pady=5)

        from config import load_config as _load_cfg
        _cfg = _load_cfg()
        self.media_type_var = tk.StringVar(value=_cfg.get("default_media_type", "movie"))
        ctk.CTkRadioButton(
            type_row, text="Movie", variable=self.media_type_var, value="movie",
        ).pack(side="left", padx=(0, 10))
        ctk.CTkRadioButton(
            type_row, text="TV Show", variable=self.media_type_var, value="tvshow",
        ).pack(side="left")

        # -- Actions --
        ctk.CTkLabel(self, text="Actions", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        action_frame = ctk.CTkFrame(self)
        action_frame.pack(fill="x", padx=10, pady=5)

        btn_row = ctk.CTkFrame(action_frame, fg_color="transparent")
        btn_row.pack(fill="x", padx=10, pady=5)

        self.scrape_btn = ctk.CTkButton(
            btn_row, text="Scrape & Rename", command=self._on_scrape,
        )
        self.scrape_btn.pack(side="left", padx=(0, 5))

        self.subs_btn = ctk.CTkButton(
            btn_row, text="Download Subtitles", command=self._on_subs,
        )
        self.subs_btn.pack(side="left", padx=(0, 5))

        self.abort_btn = ctk.CTkButton(
            btn_row, text="Abort", command=self._on_abort, state="disabled",
        )
        self.abort_btn.pack(side="left")

        # -- Progress --
        ctk.CTkLabel(self, text="Progress", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        progress_frame = ctk.CTkFrame(self)
        progress_frame.pack(fill="x", padx=10, pady=5)

        self.progress_bar = ctk.CTkProgressBar(progress_frame)
        self.progress_bar.pack(fill="x", padx=10, pady=(5, 0))
        self.progress_bar.configure(mode="indeterminate")
        self.progress_bar.set(0)

        self.status_label = ctk.CTkLabel(progress_frame, text="Idle")
        self.status_label.pack(padx=10, pady=(0, 5))

        # -- Log --
        ctk.CTkLabel(self, text="Log", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        log_frame = ctk.CTkFrame(self)
        log_frame.pack(fill="both", expand=True, padx=10, pady=(5, 10))

        self.log_text = ctk.CTkTextbox(log_frame, height=200, wrap="word", state="disabled")
        self.log_text.pack(fill="both", expand=True, padx=10, pady=5)

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

        self.scrape_btn.configure(state="disabled")
        self.subs_btn.configure(state="disabled")
        self.abort_btn.configure(state="normal")
        self._aborted = False

        # Clear log
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

        self.progress_bar.start()
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
        self.abort_btn.configure(state="disabled")
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
                    self.log_text.configure(state="normal")
                    self.log_text.insert("end", payload + "\n")
                    self.log_text.see("end")
                    self.log_text.configure(state="disabled")

                elif msg_type == "tmm_done":
                    self.progress_bar.stop()
                    action = payload
                    msg = (
                        "Scrape & rename complete"
                        if action == "scrape"
                        else "Subtitle download complete"
                    )
                    self.status_label.configure(text=msg)
                    self.scrape_btn.configure(state="normal")
                    self.subs_btn.configure(state="normal")
                    self.abort_btn.configure(state="disabled")
                    self.app.set_status(msg)
                    messagebox.showinfo("tinyMediaManager", msg)

                elif msg_type == "tmm_err":
                    self.progress_bar.stop()
                    self.status_label.configure(text="Failed")
                    self.scrape_btn.configure(state="normal")
                    self.subs_btn.configure(state="normal")
                    self.abort_btn.configure(state="disabled")
                    self.app.set_status("tMM operation failed")
                    messagebox.showerror("tinyMediaManager Error", str(payload))

        except queue.Empty:
            pass

        # Keep polling while an action is running
        if str(self.scrape_btn.cget("state")) == "disabled":
            self.after(100, self._poll_queue)
