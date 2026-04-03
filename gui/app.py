"""Main AutoRipper application window."""

from __future__ import annotations

import logging
import os
import tkinter as tk
from tkinter import filedialog, messagebox

import customtkinter as ctk

from config import load_config, save_config
from core.logger import APP_NAME, VERSION
from core.organizer import build_movie_path, organize_file, clean_filename
from core.metadata import search_media
from core.job_queue import JobQueue
from gui.rip_tab import RipTab
from gui.encode_tab import EncodeTab
from gui.scrape_tab import ScrapeTab
from gui.queue_tab import QueueTab

log = logging.getLogger(__name__)

ctk.set_appearance_mode("system")
ctk.set_default_color_theme("blue")


class AutoRipperApp(ctk.CTk):
    """Root window containing tabbed interface for rip, organize, and settings."""

    def __init__(self):
        super().__init__()
        self.title("AutoRipper")
        self.geometry("900x650")
        self.minsize(700, 500)

        self._build_menu()
        self._build_ui()
        self.protocol("WM_DELETE_WINDOW", self._on_quit)

    # ------------------------------------------------------------------ Menu
    def _build_menu(self):
        menubar = tk.Menu(self)

        app_menu = tk.Menu(menubar, name="apple", tearoff=0)
        app_menu.add_command(label="About AutoRipper", command=self._show_about)
        app_menu.add_separator()
        app_menu.add_command(label="Settings…", command=self._show_settings, accelerator="⌘,")
        app_menu.add_separator()
        app_menu.add_command(label="Quit AutoRipper", command=self._on_quit, accelerator="⌘Q")
        menubar.add_cascade(menu=app_menu)

        self.config(menu=menubar)
        self.bind_all("<Command-q>", lambda _: self._on_quit())
        self.bind_all("<Command-comma>", lambda _: self._show_settings())

    def _show_about(self):
        messagebox.showinfo(
            "About AutoRipper",
            f"AutoRipper {VERSION}\n\n"
            "Automated DVD/Blu-ray ripping pipeline.\n"
            "Rip → Encode → Organize → Scrape\n\n"
            "github.com/stevenob/AutoRipper",
        )

    def _show_settings(self):
        self.tabview.set("Settings")

    def _on_quit(self):
        log.info("Application closing")
        self.destroy()

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        self.tabview = ctk.CTkTabview(self)
        self.tabview.pack(fill="both", expand=True, padx=5, pady=(5, 0))

        # Add tabs
        rip_frame = self.tabview.add("Rip")
        encode_frame = self.tabview.add("Encode")
        scrape_frame = self.tabview.add("Scrape")
        queue_frame = self.tabview.add("Queue")
        settings_frame = self.tabview.add("Settings")

        # Create tab contents
        self.rip_tab = RipTab(rip_frame, app=self)
        self.rip_tab.pack(fill="both", expand=True)

        self.encode_tab = EncodeTab(encode_frame, app=self)
        self.encode_tab.pack(fill="both", expand=True)

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
            side="left", fill="x", expand=True, padx=(0, 5)
        )
        ctk.CTkButton(row5, text="Test", command=self._test_discord, width=60).pack(side="left")

        # -- NAS Upload --
        ctk.CTkLabel(frame, text="NAS Upload (optional)", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(10, 0)
        )
        nas_group = ctk.CTkFrame(frame)
        nas_group.pack(fill="x", padx=10, pady=(5, 5))

        nas_row0 = ctk.CTkFrame(nas_group, fg_color="transparent")
        nas_row0.pack(fill="x", padx=10, pady=5)
        self.settings_nas_enabled_var = tk.BooleanVar(value=config.get("nas_upload_enabled", False))
        ctk.CTkCheckBox(
            nas_row0, text="Copy to NAS after processing", variable=self.settings_nas_enabled_var,
            onvalue=True, offvalue=False,
        ).pack(side="left")

        nas_row1 = ctk.CTkFrame(nas_group, fg_color="transparent")
        nas_row1.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(nas_row1, text="Movies folder:").pack(side="left", padx=(0, 5))
        self.settings_nas_movies_var = tk.StringVar(value=config.get("nas_movies_path", ""))
        ctk.CTkEntry(nas_row1, textvariable=self.settings_nas_movies_var).pack(
            side="left", fill="x", expand=True, padx=(0, 5)
        )
        ctk.CTkButton(nas_row1, text="Browse…", width=80,
                       command=lambda: self._browse_nas("movies")).pack(side="left")

        nas_row2 = ctk.CTkFrame(nas_group, fg_color="transparent")
        nas_row2.pack(fill="x", padx=10, pady=(0, 5))
        ctk.CTkLabel(nas_row2, text="TV Shows folder:").pack(side="left", padx=(0, 5))
        self.settings_nas_tv_var = tk.StringVar(value=config.get("nas_tv_path", ""))
        ctk.CTkEntry(nas_row2, textvariable=self.settings_nas_tv_var).pack(
            side="left", fill="x", expand=True, padx=(0, 5)
        )
        ctk.CTkButton(nas_row2, text="Browse…", width=80,
                       command=lambda: self._browse_nas("tv")).pack(side="left")

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

    def _browse_nas(self, kind: str):
        d = filedialog.askdirectory(title=f"Select NAS {kind} folder")
        if d:
            if kind == "movies":
                self.settings_nas_movies_var.set(d)
            else:
                self.settings_nas_tv_var.set(d)

    def _save_settings(self):
        config = {
            "output_dir": self.settings_output_var.get().strip(),
            "tmdb_api_key": self.settings_tmdb_var.get().strip(),
            "makemkv_path": self.settings_mkv_var.get().strip(),
            "handbrake_path": self.settings_hb_var.get().strip(),
            "discord_webhook": self.settings_discord_var.get().strip(),
            "nas_movies_path": self.settings_nas_movies_var.get().strip(),
            "nas_tv_path": self.settings_nas_tv_var.get().strip(),
            "nas_upload_enabled": self.settings_nas_enabled_var.get(),
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

    def _test_discord(self):
        """Send a simulated job card to preview Discord output."""
        import threading
        import time
        from core.discord_notify import JobCard

        webhook = self.settings_discord_var.get().strip()
        if not webhook:
            messagebox.showwarning("Discord", "Enter a webhook URL first.")
            return

        self.set_status("Sending test card…")

        def _run():
            card = JobCard("The Matrix (1999)", nas_enabled=True)
            card.finish("rip", detail="25.3 GB · 8m12s")
            card.start("encode")
            time.sleep(1.5)
            card.finish("encode", detail="25.3 GB → 4.1 GB · HQ 1080p30 Surround · 12m34s")
            card.start("organize")
            time.sleep(1.0)
            card.finish("organize")
            card.start("scrape")
            time.sleep(1.0)
            card.finish("scrape")
            card.start("nas")
            time.sleep(1.0)
            card.finish("nas", detail="/Volumes/NAS/Movies/The Matrix (1999) · 2m06s")
            card.complete(footer="Total: 25.3 GB → 4.1 GB · 22m52s")

        threading.Thread(target=_run, daemon=True).start()

    # --------------------------------------------------------- inter-tab API
    def on_rip_complete(self, file_path: str, disc_name: str = "", auto_start: bool = False, resolution: str = "", rip_elapsed: float = 0.0):
        """Called by RipTab when a rip finishes."""
        if auto_start:
            self.job_queue.add_job(disc_name, file_path, rip_elapsed=rip_elapsed)
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
                return
        else:
            self.set_status("Skipped organize — no disc name or output dir")
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
