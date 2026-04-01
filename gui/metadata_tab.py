"""Organize tab — search TMDb metadata and organize ripped files."""

from __future__ import annotations

import os
import queue
import threading
import tkinter as tk
from tkinter import ttk, messagebox, filedialog

import customtkinter as ctk

from core.metadata import (
    search_media,
    get_movie_details,
    get_tv_details,
    get_season_episodes,
    clean_disc_name,
    MediaResult,
)
from core.organizer import build_movie_path, build_tv_path, organize_file, preview_organization
from config import load_config


class MetadataTab(ctk.CTkFrame):
    """Tab for searching TMDb and organizing ripped files into a media library."""

    def __init__(self, parent, app):
        super().__init__(parent)
        self.app = app
        self._msg_queue: queue.Queue = queue.Queue()
        self._search_results: list[MediaResult] = []
        self._selected_result: MediaResult | None = None

        self._build_ui()

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        # -- File section --
        ctk.CTkLabel(self, text="Ripped File", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(10, 0)
        )
        file_frame = ctk.CTkFrame(self)
        file_frame.pack(fill="x", padx=10, pady=(5, 5))

        self.file_var = tk.StringVar()
        ctk.CTkLabel(file_frame, text="File:").pack(side="left", padx=(10, 5), pady=5)
        ctk.CTkEntry(file_frame, textvariable=self.file_var, state="disabled").pack(
            side="left", fill="x", expand=True, pady=5
        )
        ctk.CTkButton(file_frame, text="Browse…", command=self._browse_file, width=80).pack(
            side="left", padx=(5, 10), pady=5
        )

        # -- Search section --
        ctk.CTkLabel(self, text="TMDb Search", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        search_frame = ctk.CTkFrame(self)
        search_frame.pack(fill="x", padx=10, pady=5)

        row = ctk.CTkFrame(search_frame, fg_color="transparent")
        row.pack(fill="x", padx=10, pady=5)

        self.search_var = tk.StringVar()
        ctk.CTkLabel(row, text="Query:").pack(side="left", padx=(0, 5))
        self.search_entry = ctk.CTkEntry(row, textvariable=self.search_var)
        self.search_entry.pack(side="left", fill="x", expand=True, padx=(0, 5))
        self.search_btn = ctk.CTkButton(row, text="Search TMDb", command=self._on_search)
        self.search_btn.pack(side="left")

        # Results list (KEEP ttk.Treeview)
        self.results_tree = ttk.Treeview(
            search_frame,
            columns=("title", "year", "type"),
            show="headings",
            height=5,
            selectmode="browse",
        )
        self.results_tree.heading("title", text="Title")
        self.results_tree.heading("year", text="Year")
        self.results_tree.heading("type", text="Type")
        self.results_tree.column("title", width=350)
        self.results_tree.column("year", width=80, anchor="center")
        self.results_tree.column("type", width=80, anchor="center")
        self.results_tree.pack(fill="x", padx=10, pady=(0, 5))
        self.results_tree.bind("<<TreeviewSelect>>", self._on_result_select)

        # -- Detail / Organize section --
        ctk.CTkLabel(self, text="Metadata & Organization", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        detail_frame = ctk.CTkFrame(self)
        detail_frame.pack(fill="both", expand=True, padx=10, pady=5)

        # Media type selection
        type_row = ctk.CTkFrame(detail_frame, fg_color="transparent")
        type_row.pack(fill="x", padx=10, pady=(5, 0))
        ctk.CTkLabel(type_row, text="Media type:").pack(side="left", padx=(0, 10))
        self.media_type_var = tk.StringVar(value="movie")
        ctk.CTkRadioButton(
            type_row, text="Movie", variable=self.media_type_var, value="movie",
            command=self._toggle_fields,
        ).pack(side="left", padx=(0, 10))
        ctk.CTkRadioButton(
            type_row, text="TV Show", variable=self.media_type_var, value="tv",
            command=self._toggle_fields,
        ).pack(side="left")

        # Movie fields
        self.movie_frame = ctk.CTkFrame(detail_frame, fg_color="transparent")

        r = ctk.CTkFrame(self.movie_frame, fg_color="transparent")
        r.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(r, text="Title:").pack(side="left", padx=(0, 5))
        self.movie_title_var = tk.StringVar()
        ctk.CTkEntry(r, textvariable=self.movie_title_var).pack(
            side="left", fill="x", expand=True
        )

        r2 = ctk.CTkFrame(self.movie_frame, fg_color="transparent")
        r2.pack(fill="x", padx=10, pady=(0, 5))
        ctk.CTkLabel(r2, text="Year:").pack(side="left", padx=(0, 5))
        self.movie_year_var = tk.StringVar()
        ctk.CTkEntry(r2, textvariable=self.movie_year_var, width=80).pack(side="left")

        # TV fields
        self.tv_frame = ctk.CTkFrame(detail_frame, fg_color="transparent")

        r3 = ctk.CTkFrame(self.tv_frame, fg_color="transparent")
        r3.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(r3, text="Show:").pack(side="left", padx=(0, 5))
        self.tv_show_var = tk.StringVar()
        ctk.CTkEntry(r3, textvariable=self.tv_show_var).pack(
            side="left", fill="x", expand=True
        )

        r4 = ctk.CTkFrame(self.tv_frame, fg_color="transparent")
        r4.pack(fill="x", padx=10, pady=(0, 5))
        ctk.CTkLabel(r4, text="Season:").pack(side="left", padx=(0, 5))
        self.tv_season_var = tk.IntVar(value=1)
        ctk.CTkEntry(r4, textvariable=self.tv_season_var, width=60).pack(
            side="left", padx=(0, 15)
        )
        ctk.CTkLabel(r4, text="Episode:").pack(side="left", padx=(0, 5))
        self.tv_episode_var = tk.IntVar(value=1)
        ctk.CTkEntry(r4, textvariable=self.tv_episode_var, width=60).pack(
            side="left"
        )

        r5 = ctk.CTkFrame(self.tv_frame, fg_color="transparent")
        r5.pack(fill="x", padx=10, pady=(0, 5))
        ctk.CTkLabel(r5, text="Episode name:").pack(side="left", padx=(0, 5))
        self.tv_ep_name_var = tk.StringVar()
        ctk.CTkEntry(r5, textvariable=self.tv_ep_name_var).pack(
            side="left", fill="x", expand=True
        )

        # Show movie fields by default
        self.movie_frame.pack(fill="x")

        # -- Output override --
        out_row = ctk.CTkFrame(detail_frame, fg_color="transparent")
        out_row.pack(fill="x", padx=10, pady=5)
        ctk.CTkLabel(out_row, text="Output dir:").pack(side="left", padx=(0, 5))
        self.output_dir_var = tk.StringVar(value=load_config().get("output_dir", ""))
        ctk.CTkEntry(out_row, textvariable=self.output_dir_var).pack(
            side="left", fill="x", expand=True, padx=(0, 5)
        )
        ctk.CTkButton(out_row, text="Browse…", command=self._browse_output, width=80).pack(side="left")

        # -- Preview / Organize --
        action_frame = ctk.CTkFrame(detail_frame, fg_color="transparent")
        action_frame.pack(fill="x", padx=10, pady=5)
        ctk.CTkButton(action_frame, text="Preview", command=self._on_preview).pack(
            side="left", padx=(0, 5)
        )
        ctk.CTkButton(action_frame, text="Organize", command=self._on_organize).pack(
            side="left"
        )

        self.preview_var = tk.StringVar(value="")
        ctk.CTkLabel(
            detail_frame, textvariable=self.preview_var, wraplength=700, text_color="gray"
        ).pack(fill="x", padx=10, pady=(0, 10))

    # --------------------------------------------------------- field toggle
    def _toggle_fields(self):
        self.movie_frame.pack_forget()
        self.tv_frame.pack_forget()
        if self.media_type_var.get() == "movie":
            self.movie_frame.pack(fill="x")
        else:
            self.tv_frame.pack(fill="x")

    # --------------------------------------------------------- file browse
    def _browse_file(self):
        path = filedialog.askopenfilename(
            title="Select ripped MKV file",
            filetypes=[("MKV files", "*.mkv"), ("All files", "*.*")],
        )
        if path:
            self.set_file(path)

    def _browse_output(self):
        d = filedialog.askdirectory(title="Select output directory")
        if d:
            self.output_dir_var.set(d)

    # --------------------------------------------------------- public API
    def set_file(self, path: str, disc_name: str = ""):
        """Set the ripped file path (called by parent app after ripping)."""
        self.file_var.set(path)
        if disc_name:
            cleaned = clean_disc_name(disc_name)
            self.search_var.set(cleaned)

    # --------------------------------------------------------- search logic
    def _on_search(self):
        query = self.search_var.get().strip()
        if not query:
            messagebox.showwarning("Empty query", "Enter a search query first.")
            return
        self.search_btn.configure(state="disabled")
        self.app.set_status("Searching TMDb…")
        threading.Thread(target=self._search_worker, args=(query,), daemon=True).start()
        self.after(100, self._poll_queue)

    def _search_worker(self, query: str):
        try:
            results = search_media(query)
            self._msg_queue.put(("search_ok", results))
        except Exception as exc:
            self._msg_queue.put(("search_err", str(exc)))

    def _on_result_select(self, _event):
        sel = self.results_tree.selection()
        if not sel:
            return
        idx = int(sel[0])
        if idx < 0 or idx >= len(self._search_results):
            return
        result = self._search_results[idx]
        self._selected_result = result

        self.media_type_var.set(result.media_type)
        self._toggle_fields()

        if result.media_type == "movie":
            self.movie_title_var.set(result.title)
            self.movie_year_var.set(str(result.year) if result.year else "")
        else:
            self.tv_show_var.set(result.title)
            self.tv_season_var.set(1)
            self.tv_episode_var.set(1)
            self.tv_ep_name_var.set("")

    # -------------------------------------------------------- path building
    def _build_dest_path(self) -> str | None:
        output_dir = self.output_dir_var.get().strip()
        if not output_dir:
            messagebox.showerror("Error", "Output directory is not set.")
            return None

        if self.media_type_var.get() == "movie":
            title = self.movie_title_var.get().strip()
            if not title:
                messagebox.showwarning("Missing info", "Enter a movie title.")
                return None
            year_str = self.movie_year_var.get().strip()
            year = int(year_str) if year_str.isdigit() else None
            return build_movie_path(output_dir, title, year)
        else:
            show = self.tv_show_var.get().strip()
            if not show:
                messagebox.showwarning("Missing info", "Enter a show name.")
                return None
            season = self.tv_season_var.get()
            episode = self.tv_episode_var.get()
            ep_name = self.tv_ep_name_var.get().strip() or None
            return build_tv_path(output_dir, show, season, episode, ep_name)

    # -------------------------------------------------------- preview / org
    def _on_preview(self):
        source = self.file_var.get().strip()
        if not source:
            messagebox.showwarning("No file", "No ripped file selected.")
            return
        dest = self._build_dest_path()
        if not dest:
            return
        info = preview_organization(source, dest)
        exists_note = " (file already exists — will be renamed)" if info["exists"] else ""
        self.preview_var.set(f"→ {info['destination']}{exists_note}")
        self.app.set_status("Preview ready")

    def _on_organize(self):
        source = self.file_var.get().strip()
        if not source:
            messagebox.showwarning("No file", "No ripped file selected.")
            return
        if not os.path.isfile(source):
            messagebox.showerror("Error", f"Source file not found:\n{source}")
            return
        dest = self._build_dest_path()
        if not dest:
            return

        try:
            final = organize_file(source, dest)
            self.preview_var.set(f"✓ Organized to: {final}")
            self.app.set_status("File organized successfully")
            messagebox.showinfo("Success", f"File organized to:\n{final}")
        except Exception as exc:
            messagebox.showerror("Error", f"Failed to organize file:\n{exc}")

    # --------------------------------------------------- queue poller
    def _poll_queue(self):
        try:
            while True:
                msg_type, payload = self._msg_queue.get_nowait()

                if msg_type == "search_ok":
                    self._search_results = payload
                    self.results_tree.delete(*self.results_tree.get_children())
                    for i, r in enumerate(payload):
                        year_str = str(r.year) if r.year else ""
                        self.results_tree.insert(
                            "", "end", iid=str(i),
                            values=(r.title, year_str, r.media_type.title()),
                        )
                    self.search_btn.configure(state="normal")
                    count = len(payload)
                    self.app.set_status(
                        f"Found {count} result{'s' if count != 1 else ''}"
                    )
                    if count == 0:
                        messagebox.showinfo("No results", "No matches found on TMDb.")

                elif msg_type == "search_err":
                    self.search_btn.configure(state="normal")
                    self.app.set_status("Search failed")
                    messagebox.showerror("Search Error", str(payload))

        except queue.Empty:
            pass

        if str(self.search_btn.cget("state")) == "disabled":
            self.after(100, self._poll_queue)
