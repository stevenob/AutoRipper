"""Encode tab — encode ripped MKV files using HandBrake."""

from __future__ import annotations

import os
import queue
import subprocess
import threading
import tkinter as tk
from tkinter import ttk, messagebox, filedialog

from core.handbrake import (
    list_presets,
    scan_tracks,
    encode,
    HandBrakeError,
    HandBrakeNotFoundError,
)


class EncodeTab(ttk.Frame):
    """Tab for encoding ripped MKV files with HandBrake."""

    def __init__(self, parent, app):
        super().__init__(parent)
        self.app = app
        self._msg_queue: queue.Queue = queue.Queue()
        self._disc_name: str = ""
        self._audio_vars: list[tuple[int, tk.BooleanVar]] = []
        self._subtitle_vars: list[tuple[int, tk.BooleanVar]] = []
        self._proc: subprocess.Popen | None = None
        self._aborted = False

        self._build_ui()
        self._load_presets()

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        # -- Input file section --
        file_frame = ttk.LabelFrame(self, text="Input File")
        file_frame.pack(fill=tk.X, padx=10, pady=(10, 5))

        file_row = ttk.Frame(file_frame)
        file_row.pack(fill=tk.X, padx=10, pady=5)

        self.file_var = tk.StringVar(value="No file selected")
        ttk.Label(file_row, textvariable=self.file_var, anchor=tk.W).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )
        ttk.Button(file_row, text="Browse…", command=self._browse_file).pack(
            side=tk.RIGHT
        )

        # -- Preset section --
        preset_frame = ttk.LabelFrame(self, text="Encoding Preset")
        preset_frame.pack(fill=tk.X, padx=10, pady=5)

        preset_row = ttk.Frame(preset_frame)
        preset_row.pack(fill=tk.X, padx=10, pady=5)

        from config import load_config as _load_cfg
        _cfg = _load_cfg()
        self.preset_var = tk.StringVar(value=_cfg.get("default_preset", "HQ 1080p30 Surround"))
        self.preset_combo = ttk.Combobox(
            preset_row, textvariable=self.preset_var, state="readonly", width=40
        )
        self.preset_combo.pack(side=tk.LEFT, fill=tk.X, expand=True)

        # -- Audio tracks section --
        self.audio_frame = ttk.LabelFrame(self, text="Audio Tracks")
        self.audio_frame.pack(fill=tk.X, padx=10, pady=5)

        self.audio_inner = ttk.Frame(self.audio_frame)
        self.audio_inner.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(self.audio_inner, text="Scan a file to see audio tracks").pack(
            anchor=tk.W
        )

        # -- Subtitle tracks section --
        self.subtitle_frame = ttk.LabelFrame(self, text="Subtitle Tracks")
        self.subtitle_frame.pack(fill=tk.X, padx=10, pady=5)

        self.subtitle_inner = ttk.Frame(self.subtitle_frame)
        self.subtitle_inner.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(self.subtitle_inner, text="Scan a file to see subtitle tracks").pack(
            anchor=tk.W
        )

        # -- Output section --
        output_frame = ttk.LabelFrame(self, text="Output File")
        output_frame.pack(fill=tk.X, padx=10, pady=5)

        output_row = ttk.Frame(output_frame)
        output_row.pack(fill=tk.X, padx=10, pady=5)

        self.output_var = tk.StringVar(value="")
        ttk.Label(output_row, textvariable=self.output_var, anchor=tk.W).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        # -- Encode button + progress --
        action_frame = ttk.LabelFrame(self, text="Progress")
        action_frame.pack(fill=tk.X, padx=10, pady=(5, 10))

        btn_row = ttk.Frame(action_frame)
        btn_row.pack(fill=tk.X, padx=10, pady=(5, 0))

        self.encode_btn = ttk.Button(
            btn_row, text="Encode", command=self._on_encode, state=tk.DISABLED
        )
        self.encode_btn.pack(side=tk.LEFT)

        self.abort_btn = ttk.Button(
            btn_row, text="Abort", command=self._on_abort, state=tk.DISABLED
        )
        self.abort_btn.pack(side=tk.LEFT, padx=(5, 0))

        self.progress_var = tk.IntVar(value=0)
        self.progress_bar = ttk.Progressbar(
            action_frame, variable=self.progress_var, maximum=100
        )
        self.progress_bar.pack(fill=tk.X, padx=10, pady=(5, 0))

        self.progress_label = ttk.Label(action_frame, text="Idle")
        self.progress_label.pack(padx=10, pady=(0, 5))

        # -- Log output --
        log_frame = ttk.LabelFrame(self, text="Log")
        log_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=(0, 10))

        self.log_text = tk.Text(log_frame, height=6, wrap=tk.WORD, state=tk.DISABLED)
        log_scroll = ttk.Scrollbar(log_frame, orient=tk.VERTICAL, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=log_scroll.set)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(10, 0), pady=5)
        log_scroll.pack(side=tk.RIGHT, fill=tk.Y, padx=(0, 10), pady=5)

    # --------------------------------------------------------- file handling
    def _browse_file(self):
        path = filedialog.askopenfilename(
            title="Select MKV file",
            filetypes=[("MKV files", "*.mkv"), ("All files", "*.*")],
        )
        if path:
            self.set_file(path)

    def set_file(self, file_path: str, disc_name: str = ""):
        """Set the input file path (called by app after ripping)."""
        self.file_var.set(file_path)
        self._disc_name = disc_name
        self._update_output_path()
        self.encode_btn.configure(state=tk.NORMAL)
        self._scan_file_tracks(file_path)

    def _update_output_path(self):
        """Compute the output path based on the input file."""
        input_path = self.file_var.get()
        if not input_path or input_path == "No file selected":
            self.output_var.set("")
            return
        base, ext = os.path.splitext(input_path)
        self.output_var.set(f"{base}_encoded.mkv")

    # --------------------------------------------------------- preset loading
    def _load_presets(self):
        """Load HandBrake presets in a background thread."""
        threading.Thread(target=self._preset_worker, daemon=True).start()
        self.after(100, self._poll_queue)

    def _preset_worker(self):
        try:
            presets = list_presets()
            self._msg_queue.put(("presets_ok", presets))
        except (HandBrakeNotFoundError, HandBrakeError) as exc:
            self._msg_queue.put(("presets_err", str(exc)))
        except Exception as exc:
            self._msg_queue.put(("presets_err", f"Unexpected error: {exc}"))

    # --------------------------------------------------------- track scanning
    def _scan_file_tracks(self, file_path: str):
        """Scan audio/subtitle tracks in a background thread."""
        self.progress_label.configure(text="Scanning tracks…")
        self.progress_bar.configure(mode="indeterminate")
        self.progress_bar.start(15)
        self.encode_btn.configure(state=tk.DISABLED)

        threading.Thread(
            target=self._scan_worker, args=(file_path,), daemon=True
        ).start()
        self.after(100, self._poll_queue)

    def _scan_worker(self, file_path: str):
        try:
            tracks = scan_tracks(file_path)
            self._msg_queue.put(("scan_ok", tracks))
        except (HandBrakeNotFoundError, HandBrakeError) as exc:
            self._msg_queue.put(("scan_err", str(exc)))
        except Exception as exc:
            self._msg_queue.put(("scan_err", f"Unexpected error: {exc}"))

    def _populate_audio_tracks(self, tracks: list[dict]):
        """Build checkboxes for audio tracks."""
        for widget in self.audio_inner.winfo_children():
            widget.destroy()
        self._audio_vars.clear()

        if not tracks:
            ttk.Label(self.audio_inner, text="No audio tracks found").pack(anchor=tk.W)
            return

        for track in tracks:
            var = tk.BooleanVar(value=True)
            self._audio_vars.append((track["index"], var))
            text = f"Track {track['index']}: {track['description']}"
            ttk.Checkbutton(self.audio_inner, text=text, variable=var).pack(
                anchor=tk.W
            )

    def _populate_subtitle_tracks(self, tracks: list[dict]):
        """Build checkboxes for subtitle tracks."""
        for widget in self.subtitle_inner.winfo_children():
            widget.destroy()
        self._subtitle_vars.clear()

        if not tracks:
            ttk.Label(self.subtitle_inner, text="No subtitle tracks found").pack(
                anchor=tk.W
            )
            return

        for track in tracks:
            var = tk.BooleanVar(value=True)
            self._subtitle_vars.append((track["index"], var))
            text = f"Track {track['index']}: {track['language']} ({track['type']})"
            ttk.Checkbutton(self.subtitle_inner, text=text, variable=var).pack(
                anchor=tk.W
            )

    # --------------------------------------------------------- encode logic
    def _on_encode(self):
        input_path = self.file_var.get()
        if not input_path or input_path == "No file selected":
            messagebox.showwarning("No file", "Select a file to encode first.")
            return

        output_path = self.output_var.get()
        if not output_path:
            messagebox.showerror("Error", "Output path is not set.")
            return

        preset = self.preset_var.get()
        if not preset:
            messagebox.showwarning("No preset", "Select an encoding preset.")
            return

        audio = [idx for idx, var in self._audio_vars if var.get()]
        subtitles = [idx for idx, var in self._subtitle_vars if var.get()]

        self.encode_btn.configure(state=tk.DISABLED)
        self.abort_btn.configure(state=tk.NORMAL)
        self._aborted = False
        self.progress_bar.configure(mode="determinate")
        self.progress_var.set(0)
        self.progress_label.configure(text="Starting encode…")
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state=tk.DISABLED)

        threading.Thread(
            target=self._encode_worker,
            args=(input_path, output_path, preset, audio, subtitles),
            daemon=True,
        ).start()
        self.after(100, self._poll_queue)

    def _on_abort(self):
        """Kill the running HandBrake process."""
        self._aborted = True
        if self._proc and self._proc.poll() is None:
            self._proc.kill()
        self.abort_btn.configure(state=tk.DISABLED)
        self.progress_label.configure(text="Aborting…")

    def _encode_worker(
        self,
        input_path: str,
        output_path: str,
        preset: str,
        audio: list[int],
        subtitles: list[int],
    ):
        def _progress_cb(percent: int, msg: str):
            self._msg_queue.put(("encode_progress", (percent, msg)))

        def _log_cb(line: str):
            self._msg_queue.put(("encode_log", line))

        def _proc_cb(proc):
            self._proc = proc

        try:
            result_path = encode(
                input_path,
                output_path,
                preset,
                audio_tracks=audio or None,
                subtitle_tracks=subtitles or None,
                progress_callback=_progress_cb,
                log_callback=_log_cb,
                proc_callback=_proc_cb,
            )
            self._msg_queue.put(("encode_done", result_path))
        except (HandBrakeNotFoundError, HandBrakeError) as exc:
            if self._aborted:
                self._msg_queue.put(("encode_err", "Encoding aborted by user"))
            else:
                self._msg_queue.put(("encode_err", str(exc)))
        except Exception as exc:
            self._msg_queue.put(("encode_err", f"Unexpected error: {exc}"))

    # --------------------------------------------------- queue poller
    def _poll_queue(self):
        try:
            while True:
                msg_type, payload = self._msg_queue.get_nowait()

                if msg_type == "presets_ok":
                    presets = payload
                    self.preset_combo["values"] = presets
                    # Keep current value if it's in the list, otherwise pick first
                    current = self.preset_var.get()
                    if presets and current not in presets:
                        self.preset_var.set(presets[0])

                elif msg_type == "presets_err":
                    self.preset_combo["values"] = ["HQ 1080p30 Surround"]
                    self.preset_var.set("HQ 1080p30 Surround")

                elif msg_type == "scan_ok":
                    tracks = payload
                    self._populate_audio_tracks(tracks.get("audio", []))
                    self._populate_subtitle_tracks(tracks.get("subtitles", []))
                    self.progress_bar.stop()
                    self.progress_bar.configure(mode="determinate")
                    self.progress_var.set(0)
                    self.progress_label.configure(text="Track scan complete")
                    self.encode_btn.configure(state=tk.NORMAL)

                elif msg_type == "scan_err":
                    self.progress_bar.stop()
                    self.progress_bar.configure(mode="determinate")
                    self.progress_var.set(0)
                    self.progress_label.configure(text="Track scan failed")
                    self.encode_btn.configure(state=tk.NORMAL)
                    messagebox.showerror("Scan Error", str(payload))

                elif msg_type == "encode_progress":
                    percent, label = payload
                    self.progress_var.set(percent)
                    self.progress_label.configure(text=label)

                elif msg_type == "encode_log":
                    self.log_text.configure(state=tk.NORMAL)
                    self.log_text.insert(tk.END, payload + "\n")
                    self.log_text.see(tk.END)
                    self.log_text.configure(state=tk.DISABLED)

                elif msg_type == "encode_err":
                    self.progress_label.configure(text="Encode failed")
                    self.encode_btn.configure(state=tk.NORMAL)
                    self.abort_btn.configure(state=tk.DISABLED)
                    messagebox.showerror("Encode Error", str(payload))

                elif msg_type == "encode_done":
                    result_path = payload
                    self.progress_var.set(100)
                    self.progress_label.configure(text="Encode complete")
                    self.encode_btn.configure(state=tk.NORMAL)
                    self.abort_btn.configure(state=tk.DISABLED)
                    self.app.set_status("Encoding complete")
                    self.app.on_encode_complete(result_path, self._disc_name)
                    messagebox.showinfo(
                        "Encode Complete",
                        f"File encoded successfully:\n{result_path}",
                    )

        except queue.Empty:
            pass

        # Keep polling while operations are in progress
        if (
            str(self.encode_btn.cget("state")) == "disabled"
            and self.file_var.get() != "No file selected"
        ):
            self.after(100, self._poll_queue)
