"""Main AutoRipper application window."""

from __future__ import annotations

import os
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

from config import load_config, save_config
from core.organizer import build_movie_path, organize_file, clean_filename
from core.metadata import search_media
from core.job_queue import JobQueue
from gui.rip_tab import RipTab
from gui.encode_tab import EncodeTab
from gui.metadata_tab import MetadataTab
from gui.tmm_tab import TmmTab
from gui.queue_tab import QueueTab


class AutoRipperApp(tk.Tk):
    """Root window containing tabbed interface for rip, organize, and settings."""

    def __init__(self):
        super().__init__()
        self.title("AutoRipper")
        self.geometry("900x650")
        self.minsize(700, 500)

        self._build_ui()

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill=tk.BOTH, expand=True)

        # Tabs
        self.rip_tab = RipTab(self.notebook, app=self)
        self.encode_tab = EncodeTab(self.notebook, app=self)
        self.metadata_tab = MetadataTab(self.notebook, app=self)
        self.tmm_tab = TmmTab(self.notebook, app=self)
        self.job_queue = JobQueue()
        self.queue_tab = QueueTab(self.notebook, app=self, job_queue=self.job_queue)
        self.settings_frame = self._build_settings_tab()

        self.notebook.add(self.rip_tab, text="Rip")
        self.notebook.add(self.encode_tab, text="Encode")
        self.notebook.add(self.metadata_tab, text="Organize")
        self.notebook.add(self.tmm_tab, text="tinyMediaManager")
        self.notebook.add(self.queue_tab, text="Queue")
        self.notebook.add(self.settings_frame, text="Settings")

        # Status bar
        self.status_var = tk.StringVar(value="Ready")
        status_bar = ttk.Label(
            self, textvariable=self.status_var, relief=tk.SUNKEN, anchor=tk.W, padding=(10, 2)
        )
        status_bar.pack(side=tk.BOTTOM, fill=tk.X)

    def _build_settings_tab(self) -> ttk.Frame:
        frame = ttk.Frame(self.notebook)
        config = load_config()

        settings_group = ttk.LabelFrame(frame, text="Application Settings")
        settings_group.pack(fill=tk.X, padx=10, pady=10)

        # Output directory
        row1 = ttk.Frame(settings_group)
        row1.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(row1, text="Output directory:").pack(side=tk.LEFT, padx=(0, 5))
        self.settings_output_var = tk.StringVar(value=config.get("output_dir", ""))
        ttk.Entry(row1, textvariable=self.settings_output_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5)
        )
        ttk.Button(row1, text="Browse…", command=self._browse_output_dir).pack(side=tk.LEFT)

        # TMDb API key
        row2 = ttk.Frame(settings_group)
        row2.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(row2, text="TMDb API key:").pack(side=tk.LEFT, padx=(0, 5))
        self.settings_tmdb_var = tk.StringVar(value=config.get("tmdb_api_key", ""))
        ttk.Entry(row2, textvariable=self.settings_tmdb_var, show="•").pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        # MakeMKV binary path
        row3 = ttk.Frame(settings_group)
        row3.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(row3, text="MakeMKV path:").pack(side=tk.LEFT, padx=(0, 5))
        self.settings_mkv_var = tk.StringVar(value=config.get("makemkv_path", ""))
        ttk.Entry(row3, textvariable=self.settings_mkv_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        # HandBrake binary path
        row4 = ttk.Frame(settings_group)
        row4.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(row4, text="HandBrake path:").pack(side=tk.LEFT, padx=(0, 5))
        self.settings_hb_var = tk.StringVar(
            value=config.get("handbrake_path", "/opt/homebrew/bin/HandBrakeCLI")
        )
        ttk.Entry(row4, textvariable=self.settings_hb_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        # tinyMediaManager path
        row5 = ttk.Frame(settings_group)
        row5.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(row5, text="tMM path:").pack(side=tk.LEFT, padx=(0, 5))
        self.settings_tmm_var = tk.StringVar(
            value=config.get(
                "tmm_path",
                "/Applications/tinyMediaManager.app/Contents/Resources/Java",
            )
        )
        ttk.Entry(row5, textvariable=self.settings_tmm_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        # -- Preferences (auto-saved) --
        prefs_group = ttk.LabelFrame(frame, text="Preferences (auto-saved)")
        prefs_group.pack(fill=tk.X, padx=10, pady=(0, 10))

        # Min duration
        prow1 = ttk.Frame(prefs_group)
        prow1.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(prow1, text="Min title duration (seconds):").pack(side=tk.LEFT, padx=(0, 5))
        self.settings_min_dur_var = tk.IntVar(value=config.get("min_duration", 120))
        ttk.Spinbox(prow1, from_=0, to=9999, width=6, textvariable=self.settings_min_dur_var,
                    command=self._auto_save_prefs).pack(side=tk.LEFT)

        # Auto-eject
        prow2 = ttk.Frame(prefs_group)
        prow2.pack(fill=tk.X, padx=10, pady=5)
        self.settings_auto_eject_var = tk.BooleanVar(value=config.get("auto_eject", True))
        ttk.Checkbutton(prow2, text="Auto-eject disc after rip", variable=self.settings_auto_eject_var,
                        command=self._auto_save_prefs).pack(side=tk.LEFT)

        # Default preset
        prow3 = ttk.Frame(prefs_group)
        prow3.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(prow3, text="Default HandBrake preset:").pack(side=tk.LEFT, padx=(0, 5))
        self.settings_preset_var = tk.StringVar(value=config.get("default_preset", "HQ 1080p30 Surround"))
        self.settings_preset_var.trace_add("write", lambda *_: self._auto_save_prefs())
        ttk.Entry(prow3, textvariable=self.settings_preset_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        # Default media type
        prow4 = ttk.Frame(prefs_group)
        prow4.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(prow4, text="Default media type:").pack(side=tk.LEFT, padx=(0, 5))
        self.settings_media_type_var = tk.StringVar(value=config.get("default_media_type", "movie"))
        self.settings_media_type_var.trace_add("write", lambda *_: self._auto_save_prefs())
        ttk.Radiobutton(prow4, text="Movie", variable=self.settings_media_type_var, value="movie").pack(
            side=tk.LEFT, padx=(0, 10)
        )
        ttk.Radiobutton(prow4, text="TV Show", variable=self.settings_media_type_var, value="tvshow").pack(
            side=tk.LEFT
        )

        # Save button
        btn_row = ttk.Frame(settings_group)
        btn_row.pack(fill=tk.X, padx=10, pady=(5, 10))
        ttk.Button(btn_row, text="Save Settings", command=self._save_settings).pack(side=tk.LEFT)

        return frame

    # --------------------------------------------------------- settings helpers
    def _browse_output_dir(self):
        d = filedialog.askdirectory(title="Select output directory")
        if d:
            self.settings_output_var.set(d)

    def _save_settings(self):
        config = {
            "output_dir": self.settings_output_var.get().strip(),
            "tmdb_api_key": self.settings_tmdb_var.get().strip(),
            "makemkv_path": self.settings_mkv_var.get().strip(),
            "handbrake_path": self.settings_hb_var.get().strip(),
            "tmm_path": self.settings_tmm_var.get().strip(),
            "min_duration": self.settings_min_dur_var.get(),
            "auto_eject": self.settings_auto_eject_var.get(),
            "default_preset": self.settings_preset_var.get().strip(),
            "default_media_type": self.settings_media_type_var.get(),
        }
        try:
            save_config(config)
            self.set_status("Settings saved")
            messagebox.showinfo("Settings", "Settings saved successfully.")
        except Exception as exc:
            messagebox.showerror("Error", f"Failed to save settings:\n{exc}")

    def _auto_save_prefs(self):
        """Silently save preferences when they change."""
        try:
            config = load_config()
            config["min_duration"] = self.settings_min_dur_var.get()
            config["auto_eject"] = self.settings_auto_eject_var.get()
            config["default_preset"] = self.settings_preset_var.get().strip()
            config["default_media_type"] = self.settings_media_type_var.get()
            save_config(config)
        except Exception:
            pass

    # --------------------------------------------------------- inter-tab API
    def on_rip_complete(self, file_path: str, disc_name: str = "", auto_start: bool = False):
        """Called by RipTab when a rip finishes."""
        if auto_start:
            # Add to job queue instead of running inline
            self.job_queue.add_job(disc_name, file_path)
            self.notebook.select(self.queue_tab)
            self.set_status(f"Queued: {disc_name}")
        else:
            # Manual mode — use encode tab as before
            self.encode_tab.set_file(file_path, disc_name, auto_start=False)
            self.notebook.select(self.encode_tab)

    def on_encode_complete(self, file_path: str, disc_name: str = ""):
        """Called by EncodeTab when encoding finishes — auto-organize and go to tMM."""
        config = load_config()
        output_dir = config.get("output_dir", "")

        if disc_name and output_dir:
            # Look up TMDb for proper title and year
            try:
                results = search_media(disc_name)
                if results:
                    title = results[0].title
                    year = results[0].year
                    dest = build_movie_path(output_dir, title, year)
                else:
                    dest = build_movie_path(output_dir, clean_filename(disc_name))
            except Exception:
                dest = build_movie_path(output_dir, clean_filename(disc_name))

            try:
                final_path = organize_file(file_path, dest)
                self.set_status(f"Organized: {os.path.basename(final_path)}")
            except Exception as exc:
                self.set_status(f"Auto-organize failed: {exc}")
                # Fall back to manual organize
                self.metadata_tab.set_file(file_path, disc_name)
                self.notebook.select(self.metadata_tab)
                return
        else:
            # No disc name or output dir — fall back to manual organize
            self.metadata_tab.set_file(file_path, disc_name)
            self.notebook.select(self.metadata_tab)
            return

        self.notebook.select(self.tmm_tab)
        self.tmm_tab.auto_scrape()

    def on_organize_complete(self):
        """Called after organizing finishes — switches to the tMM tab."""
        self.notebook.select(self.tmm_tab)
        self.tmm_tab.auto_scrape()

    def set_status(self, text: str):
        """Update the status bar text."""
        self.status_var.set(text)
