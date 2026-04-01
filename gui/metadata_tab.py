"""Organize tab — search TMDb metadata and organize ripped files."""

from __future__ import annotations

import os
import queue
import threading
import tkinter as tk
from tkinter import ttk, messagebox, filedialog

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


class MetadataTab(ttk.Frame):
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
        file_frame = ttk.LabelFrame(self, text="Ripped File")
        file_frame.pack(fill=tk.X, padx=10, pady=(10, 5))

        self.file_var = tk.StringVar()
        ttk.Label(file_frame, text="File:").pack(side=tk.LEFT, padx=(10, 5), pady=5)
        ttk.Entry(file_frame, textvariable=self.file_var, state="readonly").pack(
            side=tk.LEFT, fill=tk.X, expand=True, pady=5
        )
        ttk.Button(file_frame, text="Browse…", command=self._browse_file).pack(
            side=tk.LEFT, padx=(5, 10), pady=5
        )

        # -- Search section --
        search_frame = ttk.LabelFrame(self, text="TMDb Search")
        search_frame.pack(fill=tk.X, padx=10, pady=5)

        row = ttk.Frame(search_frame)
        row.pack(fill=tk.X, padx=10, pady=5)

        self.search_var = tk.StringVar()
        ttk.Label(row, text="Query:").pack(side=tk.LEFT, padx=(0, 5))
        self.search_entry = ttk.Entry(row, textvariable=self.search_var)
        self.search_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5))
        self.search_btn = ttk.Button(row, text="Search TMDb", command=self._on_search)
        self.search_btn.pack(side=tk.LEFT)

        # Results list
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
        self.results_tree.column("year", width=80, anchor=tk.CENTER)
        self.results_tree.column("type", width=80, anchor=tk.CENTER)
        self.results_tree.pack(fill=tk.X, padx=10, pady=(0, 5))
        self.results_tree.bind("<<TreeviewSelect>>", self._on_result_select)

        # -- Detail / Organize section --
        detail_frame = ttk.LabelFrame(self, text="Metadata && Organization")
        detail_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)

        # Media type selection
        type_row = ttk.Frame(detail_frame)
        type_row.pack(fill=tk.X, padx=10, pady=(5, 0))
        ttk.Label(type_row, text="Media type:").pack(side=tk.LEFT, padx=(0, 10))
        self.media_type_var = tk.StringVar(value="movie")
        ttk.Radiobutton(
            type_row, text="Movie", variable=self.media_type_var, value="movie",
            command=self._toggle_fields,
        ).pack(side=tk.LEFT, padx=(0, 10))
        ttk.Radiobutton(
            type_row, text="TV Show", variable=self.media_type_var, value="tv",
            command=self._toggle_fields,
        ).pack(side=tk.LEFT)

        # Movie fields
        self.movie_frame = ttk.Frame(detail_frame)

        r = ttk.Frame(self.movie_frame)
        r.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(r, text="Title:").pack(side=tk.LEFT, padx=(0, 5))
        self.movie_title_var = tk.StringVar()
        ttk.Entry(r, textvariable=self.movie_title_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        r2 = ttk.Frame(self.movie_frame)
        r2.pack(fill=tk.X, padx=10, pady=(0, 5))
        ttk.Label(r2, text="Year:").pack(side=tk.LEFT, padx=(0, 5))
        self.movie_year_var = tk.StringVar()
        ttk.Entry(r2, textvariable=self.movie_year_var, width=8).pack(side=tk.LEFT)

        # TV fields
        self.tv_frame = ttk.Frame(detail_frame)

        r3 = ttk.Frame(self.tv_frame)
        r3.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(r3, text="Show:").pack(side=tk.LEFT, padx=(0, 5))
        self.tv_show_var = tk.StringVar()
        ttk.Entry(r3, textvariable=self.tv_show_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        r4 = ttk.Frame(self.tv_frame)
        r4.pack(fill=tk.X, padx=10, pady=(0, 5))
        ttk.Label(r4, text="Season:").pack(side=tk.LEFT, padx=(0, 5))
        self.tv_season_var = tk.IntVar(value=1)
        ttk.Spinbox(r4, from_=0, to=99, textvariable=self.tv_season_var, width=5).pack(
            side=tk.LEFT, padx=(0, 15)
        )
        ttk.Label(r4, text="Episode:").pack(side=tk.LEFT, padx=(0, 5))
        self.tv_episode_var = tk.IntVar(value=1)
        ttk.Spinbox(r4, from_=0, to=999, textvariable=self.tv_episode_var, width=5).pack(
            side=tk.LEFT
        )

        r5 = ttk.Frame(self.tv_frame)
        r5.pack(fill=tk.X, padx=10, pady=(0, 5))
        ttk.Label(r5, text="Episode name:").pack(side=tk.LEFT, padx=(0, 5))
        self.tv_ep_name_var = tk.StringVar()
        ttk.Entry(r5, textvariable=self.tv_ep_name_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        # Show movie fields by default
        self.movie_frame.pack(fill=tk.X)

        # -- Output override --
        out_row = ttk.Frame(detail_frame)
        out_row.pack(fill=tk.X, padx=10, pady=5)
        ttk.Label(out_row, text="Output dir:").pack(side=tk.LEFT, padx=(0, 5))
        self.output_dir_var = tk.StringVar(value=load_config().get("output_dir", ""))
        ttk.Entry(out_row, textvariable=self.output_dir_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5)
        )
        ttk.Button(out_row, text="Browse…", command=self._browse_output).pack(side=tk.LEFT)

        # -- Preview / Organize --
        action_frame = ttk.Frame(detail_frame)
        action_frame.pack(fill=tk.X, padx=10, pady=5)
        ttk.Button(action_frame, text="Preview", command=self._on_preview).pack(
            side=tk.LEFT, padx=(0, 5)
        )
        ttk.Button(action_frame, text="Organize", command=self._on_organize).pack(
            side=tk.LEFT
        )

        self.preview_var = tk.StringVar(value="")
        ttk.Label(
            detail_frame, textvariable=self.preview_var, wraplength=700, foreground="gray"
        ).pack(fill=tk.X, padx=10, pady=(0, 10))

    # --------------------------------------------------------- field toggle
    def _toggle_fields(self):
        self.movie_frame.pack_forget()
        self.tv_frame.pack_forget()
        if self.media_type_var.get() == "movie":
            self.movie_frame.pack(fill=tk.X)
        else:
            self.tv_frame.pack(fill=tk.X)

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
        self.search_btn.configure(state=tk.DISABLED)
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
                            "", tk.END, iid=str(i),
                            values=(r.title, year_str, r.media_type.title()),
                        )
                    self.search_btn.configure(state=tk.NORMAL)
                    count = len(payload)
                    self.app.set_status(
                        f"Found {count} result{'s' if count != 1 else ''}"
                    )
                    if count == 0:
                        messagebox.showinfo("No results", "No matches found on TMDb.")

                elif msg_type == "search_err":
                    self.search_btn.configure(state=tk.NORMAL)
                    self.app.set_status("Search failed")
                    messagebox.showerror("Search Error", str(payload))

        except queue.Empty:
            pass

        if str(self.search_btn.cget("state")) == "disabled":
            self.after(100, self._poll_queue)
