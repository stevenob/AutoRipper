"""Main AutoRipper application window."""

import tkinter as tk
from tkinter import ttk, filedialog, messagebox

from config import load_config, save_config
from gui.rip_tab import RipTab
from gui.metadata_tab import MetadataTab


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
        self.metadata_tab = MetadataTab(self.notebook, app=self)
        self.settings_frame = self._build_settings_tab()

        self.notebook.add(self.rip_tab, text="Rip")
        self.notebook.add(self.metadata_tab, text="Organize")
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
        }
        try:
            save_config(config)
            self.set_status("Settings saved")
            messagebox.showinfo("Settings", "Settings saved successfully.")
        except Exception as exc:
            messagebox.showerror("Error", f"Failed to save settings:\n{exc}")

    # --------------------------------------------------------- inter-tab API
    def on_rip_complete(self, file_path: str, disc_name: str = ""):
        """Called by RipTab when a rip finishes — forwards info to the Organize tab."""
        self.metadata_tab.set_file(file_path, disc_name)
        self.notebook.select(self.metadata_tab)

    def set_status(self, text: str):
        """Update the status bar text."""
        self.status_var.set(text)
