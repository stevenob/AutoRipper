"""Encode tab — encode ripped MKV files using HandBrake."""

from __future__ import annotations

import os
import queue
import subprocess
import threading
import tkinter as tk
from tkinter import messagebox, filedialog

import customtkinter as ctk

from core.handbrake import (
    list_presets,
    scan_tracks,
    encode,
    HandBrakeError,
    HandBrakeNotFoundError,
)


class EncodeTab(ctk.CTkFrame):
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
        self._auto_start = False

        self._build_ui()
        self._load_presets()

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        # -- Input file section --
        ctk.CTkLabel(self, text="Input File", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(10, 0)
        )
        file_frame = ctk.CTkFrame(self)
        file_frame.pack(fill="x", padx=10, pady=(5, 5))

        file_row = ctk.CTkFrame(file_frame, fg_color="transparent")
        file_row.pack(fill="x", padx=10, pady=5)

        self.file_var = tk.StringVar(value="No file selected")
        ctk.CTkLabel(file_row, textvariable=self.file_var, anchor="w").pack(
            side="left", fill="x", expand=True
        )
        ctk.CTkButton(file_row, text="Browse…", command=self._browse_file, width=80).pack(
            side="right"
        )

        # -- Preset section --
        ctk.CTkLabel(self, text="Encoding Preset", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        preset_frame = ctk.CTkFrame(self)
        preset_frame.pack(fill="x", padx=10, pady=5)

        preset_row = ctk.CTkFrame(preset_frame, fg_color="transparent")
        preset_row.pack(fill="x", padx=10, pady=5)

        from config import load_config as _load_cfg
        _cfg = _load_cfg()
        self.preset_var = tk.StringVar(value=_cfg.get("default_preset", "HQ 1080p30 Surround"))
        self.preset_combo = ctk.CTkComboBox(
            preset_row, variable=self.preset_var, state="readonly", width=300, values=[]
        )
        self.preset_combo.pack(side="left", fill="x", expand=True)

        # Quick H.265 preset buttons
        quick_frame = ctk.CTkFrame(preset_frame, fg_color="transparent")
        quick_frame.pack(fill="x", padx=10, pady=(0, 5))
        ctk.CTkLabel(quick_frame, text="H.265 Quick:").pack(side="left", padx=(0, 5))
        for label, preset in [
            ("480p", "H.265 MKV 480p30"),
            ("720p", "H.265 MKV 720p30"),
            ("1080p", "H.265 MKV 1080p30"),
            ("4K", "H.265 MKV 2160p60 4K"),
            ("1080p HW ⚡", "H.265 Apple VideoToolbox 1080p"),
            ("4K HW ⚡", "H.265 Apple VideoToolbox 2160p 4K"),
        ]:
            ctk.CTkButton(
                quick_frame, text=label, width=90,
                command=lambda p=preset: self.preset_var.set(p),
            ).pack(side="left", padx=2)

        # -- Audio tracks section --
        ctk.CTkLabel(self, text="Audio Tracks", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        self.audio_frame = ctk.CTkFrame(self)
        self.audio_frame.pack(fill="x", padx=10, pady=5)

        self.audio_inner = ctk.CTkFrame(self.audio_frame, fg_color="transparent")
        self.audio_inner.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(self.audio_inner, text="Scan a file to see audio tracks").pack(
            anchor="w"
        )

        # -- Subtitle tracks section --
        ctk.CTkLabel(self, text="Subtitle Tracks", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        self.subtitle_frame = ctk.CTkFrame(self)
        self.subtitle_frame.pack(fill="x", padx=10, pady=5)

        self.subtitle_inner = ctk.CTkFrame(self.subtitle_frame, fg_color="transparent")
        self.subtitle_inner.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(self.subtitle_inner, text="Scan a file to see subtitle tracks").pack(
            anchor="w"
        )

        # -- Output section --
        ctk.CTkLabel(self, text="Output File", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        output_frame = ctk.CTkFrame(self)
        output_frame.pack(fill="x", padx=10, pady=5)

        output_row = ctk.CTkFrame(output_frame, fg_color="transparent")
        output_row.pack(fill="x", padx=10, pady=5)

        self.output_var = tk.StringVar(value="")
        ctk.CTkLabel(output_row, textvariable=self.output_var, anchor="w").pack(
            side="left", fill="x", expand=True
        )

        # -- Encode button + progress --
        ctk.CTkLabel(self, text="Progress", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        action_frame = ctk.CTkFrame(self)
        action_frame.pack(fill="x", padx=10, pady=(5, 10))

        btn_row = ctk.CTkFrame(action_frame, fg_color="transparent")
        btn_row.pack(fill="x", padx=10, pady=(5, 0))

        self.encode_btn = ctk.CTkButton(
            btn_row, text="Encode", command=self._on_encode, state="disabled"
        )
        self.encode_btn.pack(side="left")

        self.abort_btn = ctk.CTkButton(
            btn_row, text="Abort", command=self._on_abort, state="disabled"
        )
        self.abort_btn.pack(side="left", padx=(5, 0))

        self.progress_bar = ctk.CTkProgressBar(action_frame)
        self.progress_bar.pack(fill="x", padx=10, pady=(5, 0))
        self.progress_bar.set(0)

        self.progress_label = ctk.CTkLabel(action_frame, text="Idle")
        self.progress_label.pack(padx=10, pady=(0, 5))

        # -- Log output --
        ctk.CTkLabel(self, text="Log", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(0, 0)
        )
        log_frame = ctk.CTkFrame(self)
        log_frame.pack(fill="both", expand=True, padx=10, pady=(5, 10))

        self.log_text = ctk.CTkTextbox(log_frame, height=100, wrap="word", state="disabled")
        self.log_text.pack(fill="both", expand=True, padx=10, pady=5)

    # --------------------------------------------------------- file handling
    def _browse_file(self):
        path = filedialog.askopenfilename(
            title="Select MKV file",
            filetypes=[("MKV files", "*.mkv"), ("All files", "*.*")],
        )
        if path:
            self.set_file(path)

    def set_file(self, file_path: str, disc_name: str = "", auto_start: bool = False, resolution: str = ""):
        """Set the input file path (called by app after ripping)."""
        self.file_var.set(file_path)
        self._disc_name = disc_name
        self._auto_start = auto_start
        self._update_output_path()
        if resolution:
            self._auto_select_preset(resolution)
        self.encode_btn.configure(state="normal")
        self._scan_file_tracks(file_path)

    def _auto_select_preset(self, resolution: str):
        """Pick the best H.265 preset based on video resolution."""
        try:
            _, h = resolution.lower().split("x")
            height = int(h)
        except (ValueError, AttributeError):
            return
        if height >= 2160:
            preset = "H.265 Apple VideoToolbox 2160p 4K"
        elif height >= 1080:
            preset = "H.265 Apple VideoToolbox 1080p"
        elif height >= 720:
            preset = "H.265 MKV 720p30"
        elif height >= 576:
            preset = "H.265 MKV 576p25"
        else:
            preset = "H.265 MKV 480p30"
        self.preset_var.set(preset)

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
        self.progress_bar.start()
        self.encode_btn.configure(state="disabled")

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
            ctk.CTkLabel(self.audio_inner, text="No audio tracks found").pack(anchor="w")
            return

        for track in tracks:
            var = tk.BooleanVar(value=True)
            self._audio_vars.append((track["index"], var))
            text = f"Track {track['index']}: {track['description']}"
            ctk.CTkCheckBox(self.audio_inner, text=text, variable=var,
                            onvalue=True, offvalue=False).pack(anchor="w")

    def _populate_subtitle_tracks(self, tracks: list[dict]):
        """Build checkboxes for subtitle tracks."""
        for widget in self.subtitle_inner.winfo_children():
            widget.destroy()
        self._subtitle_vars.clear()

        if not tracks:
            ctk.CTkLabel(self.subtitle_inner, text="No subtitle tracks found").pack(
                anchor="w"
            )
            return

        for track in tracks:
            var = tk.BooleanVar(value=True)
            self._subtitle_vars.append((track["index"], var))
            text = f"Track {track['index']}: {track['language']} ({track['type']})"
            ctk.CTkCheckBox(self.subtitle_inner, text=text, variable=var,
                            onvalue=True, offvalue=False).pack(anchor="w")

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

        self.encode_btn.configure(state="disabled")
        self.abort_btn.configure(state="normal")
        self._aborted = False
        self.progress_bar.configure(mode="determinate")
        self.progress_bar.set(0)
        self.progress_label.configure(text="Starting encode…")
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

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
        self.abort_btn.configure(state="disabled")
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
                    self.preset_combo.configure(values=presets)
                    # Keep current value if it's in the list, otherwise pick first
                    current = self.preset_var.get()
                    if presets and current not in presets:
                        self.preset_var.set(presets[0])

                elif msg_type == "presets_err":
                    self.preset_combo.configure(values=["HQ 1080p30 Surround"])
                    self.preset_var.set("HQ 1080p30 Surround")

                elif msg_type == "scan_ok":
                    tracks = payload
                    self._populate_audio_tracks(tracks.get("audio", []))
                    self._populate_subtitle_tracks(tracks.get("subtitles", []))
                    self.progress_bar.stop()
                    self.progress_bar.configure(mode="determinate")
                    self.progress_bar.set(0)
                    self.progress_label.configure(text="Track scan complete")
                    self.encode_btn.configure(state="normal")
                    if self._auto_start:
                        self._auto_start = False
                        self.after(500, self._on_encode)

                elif msg_type == "scan_err":
                    self.progress_bar.stop()
                    self.progress_bar.configure(mode="determinate")
                    self.progress_bar.set(0)
                    self.progress_label.configure(text="Track scan failed")
                    self.encode_btn.configure(state="normal")
                    messagebox.showerror("Scan Error", str(payload))

                elif msg_type == "encode_progress":
                    percent, label = payload
                    self.progress_bar.set(percent / 100)
                    self.progress_label.configure(text=label)

                elif msg_type == "encode_log":
                    self.log_text.configure(state="normal")
                    self.log_text.insert("end", payload + "\n")
                    self.log_text.see("end")
                    self.log_text.configure(state="disabled")

                elif msg_type == "encode_err":
                    self.progress_label.configure(text="Encode failed")
                    self.encode_btn.configure(state="normal")
                    self.abort_btn.configure(state="disabled")
                    messagebox.showerror("Encode Error", str(payload))

                elif msg_type == "encode_done":
                    result_path = payload
                    self.progress_bar.set(1.0)
                    self.progress_label.configure(text="Encode complete")
                    self.encode_btn.configure(state="normal")
                    self.abort_btn.configure(state="disabled")
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
