"""Main AutoRipper application window."""

from __future__ import annotations

import os
import tkinter as tk
from tkinter import filedialog, messagebox

import customtkinter as ctk

from config import load_config, save_config
from core.organizer import build_movie_path, organize_file, clean_filename
from core.metadata import search_media
from core.job_queue import JobQueue
from gui.rip_tab import RipTab
from gui.encode_tab import EncodeTab
from gui.metadata_tab import MetadataTab
from gui.scrape_tab import ScrapeTab
from gui.queue_tab import QueueTab

ctk.set_appearance_mode("system")
ctk.set_default_color_theme("blue")


class AutoRipperApp(ctk.CTk):
    """Root window containing tabbed interface for rip, organize, and settings."""

    def __init__(self):
        super().__init__()
        self.title("AutoRipper")
        self.geometry("900x650")
        self.minsize(700, 500)

        self._build_ui()

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        self.tabview = ctk.CTkTabview(self)
        self.tabview.pack(fill="both", expand=True, padx=5, pady=(5, 0))

        # Add tabs
        rip_frame = self.tabview.add("Rip")
        encode_frame = self.tabview.add("Encode")
        organize_frame = self.tabview.add("Organize")
        scrape_frame = self.tabview.add("Scrape")
        queue_frame = self.tabview.add("Queue")
        settings_frame = self.tabview.add("Settings")

        # Create tab contents
        self.rip_tab = RipTab(rip_frame, app=self)
        self.rip_tab.pack(fill="both", expand=True)

        self.encode_tab = EncodeTab(encode_frame, app=self)
        self.encode_tab.pack(fill="both", expand=True)

        self.metadata_tab = MetadataTab(organize_frame, app=self)
        self.metadata_tab.pack(fill="both", expand=True)

        self.scrape_tab = ScrapeTab(scrape_frame, app=self)
        self.scrape_tab.pack(fill="both", expand=True)

        self.job_queue = JobQueue()
        self.queue_tab = QueueTab(queue_frame, app=self, job_queue=self.job_queue)
        self.queue_tab.pack(fill="both", expand=True)

        self._build_settings_tab(settings_frame)

        # Status bar
        self.status_var = tk.StringVar(value="Ready")
        status_bar = ctk.CTkLabel(self, textvariable=self.status_var, anchor="w")
        status_bar.pack(side="bottom", fill="x", padx=10, pady=(0, 5))

    def _build_settings_tab(self, frame: ctk.CTkFrame) -> None:
        config = load_config()

        ctk.CTkLabel(frame, text="Application Settings", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(10, 0)
        )
        settings_group = ctk.CTkFrame(frame)
        settings_group.pack(fill="x", padx=10, pady=(5, 10))

        # Output directory
        row1 = ctk.CTkFrame(settings_group, fg_color="transparent")
        row1.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(row1, text="Output directory:").pack(side="left", padx=(0, 5))
        self.settings_output_var = tk.StringVar(value=config.get("output_dir", ""))
        ctk.CTkEntry(row1, textvariable=self.settings_output_var).pack(
            side="left", fill="x", expand=True, padx=(0, 5)
        )
        ctk.CTkButton(row1, text="Browse…", command=self._browse_output_dir, width=80).pack(side="left")

        # TMDb API key
        row2 = ctk.CTkFrame(settings_group, fg_color="transparent")
        row2.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(row2, text="TMDb API key:").pack(side="left", padx=(0, 5))
        self.settings_tmdb_var = tk.StringVar(value=config.get("tmdb_api_key", ""))
        ctk.CTkEntry(row2, textvariable=self.settings_tmdb_var, show="•").pack(
            side="left", fill="x", expand=True
        )

        # MakeMKV binary path
        row3 = ctk.CTkFrame(settings_group, fg_color="transparent")
        row3.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(row3, text="MakeMKV path:").pack(side="left", padx=(0, 5))
        self.settings_mkv_var = tk.StringVar(value=config.get("makemkv_path", ""))
        ctk.CTkEntry(row3, textvariable=self.settings_mkv_var).pack(
            side="left", fill="x", expand=True
        )

        # HandBrake binary path
        row4 = ctk.CTkFrame(settings_group, fg_color="transparent")
        row4.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(row4, text="HandBrake path:").pack(side="left", padx=(0, 5))
        self.settings_hb_var = tk.StringVar(
            value=config.get("handbrake_path", "/opt/homebrew/bin/HandBrakeCLI")
        )
        ctk.CTkEntry(row4, textvariable=self.settings_hb_var).pack(
            side="left", fill="x", expand=True
        )

        # Discord webhook URL
        row5 = ctk.CTkFrame(settings_group, fg_color="transparent")
        row5.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(row5, text="Discord webhook:").pack(side="left", padx=(0, 5))
        self.settings_discord_var = tk.StringVar(value=config.get("discord_webhook", ""))
        ctk.CTkEntry(row5, textvariable=self.settings_discord_var).pack(
            side="left", fill="x", expand=True
        )

        # -- Preferences (auto-saved) --
        ctk.CTkLabel(frame, text="Preferences (auto-saved)", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(10, 0)
        )
        prefs_group = ctk.CTkFrame(frame)
        prefs_group.pack(fill="x", padx=10, pady=(5, 10))

        # Min duration
        prow1 = ctk.CTkFrame(prefs_group, fg_color="transparent")
        prow1.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(prow1, text="Min title duration (seconds):").pack(side="left", padx=(0, 5))
        self.settings_min_dur_var = tk.IntVar(value=config.get("min_duration", 120))
        ctk.CTkEntry(prow1, textvariable=self.settings_min_dur_var, width=80).pack(side="left")

        # Auto-eject
        prow2 = ctk.CTkFrame(prefs_group, fg_color="transparent")
        prow2.pack(fill="x", padx=10, pady=5)
        self.settings_auto_eject_var = tk.BooleanVar(value=config.get("auto_eject", True))
        ctk.CTkCheckBox(
            prow2, text="Auto-eject disc after rip", variable=self.settings_auto_eject_var,
            command=self._auto_save_prefs, onvalue=True, offvalue=False,
        ).pack(side="left")

        # Default preset
        prow3 = ctk.CTkFrame(prefs_group, fg_color="transparent")
        prow3.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(prow3, text="Default HandBrake preset:").pack(side="left", padx=(0, 5))
        self.settings_preset_var = tk.StringVar(value=config.get("default_preset", "HQ 1080p30 Surround"))
        self.settings_preset_var.trace_add("write", lambda *_: self._auto_save_prefs())
        ctk.CTkEntry(prow3, textvariable=self.settings_preset_var).pack(
            side="left", fill="x", expand=True
        )

        # Default media type
        prow4 = ctk.CTkFrame(prefs_group, fg_color="transparent")
        prow4.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(prow4, text="Default media type:").pack(side="left", padx=(0, 5))
        self.settings_media_type_var = tk.StringVar(value=config.get("default_media_type", "movie"))
        self.settings_media_type_var.trace_add("write", lambda *_: self._auto_save_prefs())
        ctk.CTkRadioButton(prow4, text="Movie", variable=self.settings_media_type_var, value="movie").pack(
            side="left", padx=(0, 10)
        )
        ctk.CTkRadioButton(prow4, text="TV Show", variable=self.settings_media_type_var, value="tvshow").pack(
            side="left"
        )

        # Save button
        btn_row = ctk.CTkFrame(settings_group, fg_color="transparent")
        btn_row.pack(fill="x", padx=10, pady=(5, 10))
        ctk.CTkButton(btn_row, text="Save Settings", command=self._save_settings).pack(side="left")

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
            "discord_webhook": self.settings_discord_var.get().strip(),
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
    def on_rip_complete(self, file_path: str, disc_name: str = "", auto_start: bool = False, resolution: str = ""):
        """Called by RipTab when a rip finishes."""
        if auto_start:
            self.job_queue.add_job(disc_name, file_path)
            self.tabview.set("Queue")
            self.set_status(f"Queued: {disc_name}")
        else:
            self.encode_tab.set_file(file_path, disc_name, auto_start=False, resolution=resolution)
            self.tabview.set("Encode")

    def on_encode_complete(self, file_path: str, disc_name: str = ""):
        """Called by EncodeTab when encoding finishes — auto-organize and scrape."""
        config = load_config()
        output_dir = config.get("output_dir", "")

        if disc_name and output_dir:
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
                self.metadata_tab.set_file(file_path, disc_name)
                self.tabview.set("Organize")
                return
        else:
            self.metadata_tab.set_file(file_path, disc_name)
            self.tabview.set("Organize")
            return

        self.scrape_tab.set_info(disc_name, os.path.dirname(final_path))
        self.tabview.set("Scrape")
        self.scrape_tab.auto_scrape()

    def on_organize_complete(self, disc_name: str = "", dest_dir: str = ""):
        """Called after organizing finishes — switches to the Scrape tab."""
        self.scrape_tab.set_info(disc_name, dest_dir)
        self.tabview.set("Scrape")
        self.scrape_tab.auto_scrape()

    def set_status(self, text: str):
        """Update the status bar text."""
        self.status_var.set(text)
