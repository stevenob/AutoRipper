"""Built-in metadata scrape tab — downloads artwork and creates NFO files."""

from __future__ import annotations

import queue
import threading
import tkinter as tk
from tkinter import ttk

from core.artwork import scrape_and_save


class ScrapeTab(ttk.Frame):
    """Tab for scraping metadata, artwork, and NFO files via TMDb."""

    def __init__(self, parent: ttk.Notebook, app: object) -> None:
        super().__init__(parent)
        self.app = app
        self._msg_queue: queue.Queue = queue.Queue()
        self._disc_name: str = ""
        self._dest_dir: str = ""
        self._running = False

        self._build_ui()

    # ------------------------------------------------------------------ UI
    def _build_ui(self) -> None:
        # -- Status section --
        status_frame = ttk.LabelFrame(self, text="Metadata Scraper")
        status_frame.pack(fill=tk.X, padx=10, pady=(10, 5))

        info_row = ttk.Frame(status_frame)
        info_row.pack(fill=tk.X, padx=10, pady=(5, 0))
        ttk.Label(info_row, text="Title:").pack(side=tk.LEFT, padx=(0, 5))
        self.title_var = tk.StringVar(value="(none)")
        ttk.Label(info_row, textvariable=self.title_var).pack(side=tk.LEFT)

        btn_row = ttk.Frame(status_frame)
        btn_row.pack(fill=tk.X, padx=10, pady=5)
        self.scrape_btn = ttk.Button(
            btn_row, text="Scrape & Download", command=self._on_scrape,
        )
        self.scrape_btn.pack(side=tk.LEFT, padx=(0, 5))

        self.progress_bar = ttk.Progressbar(status_frame, mode="indeterminate")
        self.progress_bar.pack(fill=tk.X, padx=10, pady=(0, 5))

        self.status_label = ttk.Label(status_frame, text="Idle")
        self.status_label.pack(padx=10, pady=(0, 5))

        # -- Results section --
        results_frame = ttk.LabelFrame(self, text="Results")
        results_frame.pack(fill=tk.X, padx=10, pady=5)

        self.poster_var = tk.StringVar(value="Poster: —")
        self.fanart_var = tk.StringVar(value="Fanart: —")
        self.nfo_var = tk.StringVar(value="NFO: —")
        for var in (self.poster_var, self.fanart_var, self.nfo_var):
            ttk.Label(results_frame, textvariable=var).pack(
                anchor=tk.W, padx=10, pady=2,
            )

        # -- Log section --
        log_frame = ttk.LabelFrame(self, text="Log")
        log_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=(0, 10))

        self.log_text = tk.Text(log_frame, height=12, wrap=tk.WORD, state=tk.DISABLED)
        log_scroll = ttk.Scrollbar(
            log_frame, orient=tk.VERTICAL, command=self.log_text.yview,
        )
        self.log_text.configure(yscrollcommand=log_scroll.set)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(10, 0), pady=5)
        log_scroll.pack(side=tk.RIGHT, fill=tk.Y, padx=(0, 10), pady=5)

    # --------------------------------------------------------- public API
    def set_info(self, disc_name: str, dest_dir: str) -> None:
        """Set the disc name and destination directory (called by app after organize)."""
        self._disc_name = disc_name
        self._dest_dir = dest_dir
        self.title_var.set(disc_name or "(none)")

    def auto_scrape(self) -> None:
        """Auto-start scraping (called by app in Full Auto mode)."""
        self.after(500, self._on_scrape)

    # --------------------------------------------------------- actions
    def _on_scrape(self) -> None:
        if self._running:
            return
        if not self._disc_name or not self._dest_dir:
            self.status_label.configure(text="No title or destination set")
            return

        self._running = True
        self.scrape_btn.configure(state=tk.DISABLED)

        # Clear log
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state=tk.DISABLED)

        # Reset results
        self.poster_var.set("Poster: —")
        self.fanart_var.set("Fanart: —")
        self.nfo_var.set("NFO: —")

        self.progress_bar.start(15)
        self.status_label.configure(text="Scraping…")
        self.app.set_status("Scraping metadata…")

        threading.Thread(target=self._scrape_worker, daemon=True).start()
        self.after(100, self._poll_queue)

    # --------------------------------------------------------- worker
    def _scrape_worker(self) -> None:
        poster_ok = False
        fanart_ok = False
        nfo_ok = False

        def _log(line: str) -> None:
            self._msg_queue.put(("log", line))

        try:
            _log(f"Searching TMDb for '{self._disc_name}'…")

            from core.metadata import search_media, get_movie_details, get_tv_details, MediaResult
            from core.artwork import download_artwork, create_nfo

            results = search_media(self._disc_name)
            if not results:
                _log("No results found on TMDb.")
                self._msg_queue.put(("done", (False, False, False)))
                return

            media = results[0]
            _log(f"Found: {media.title} ({media.year}) [{media.media_type}]")

            # Refresh full details
            if media.media_type == "movie":
                details = get_movie_details(media.tmdb_id)
                if details:
                    media = details
            else:
                tv = get_tv_details(media.tmdb_id)
                if tv:
                    media = MediaResult(
                        title=tv["title"],
                        year=tv["year"],
                        media_type="tv",
                        tmdb_id=media.tmdb_id,
                        overview=media.overview,
                        poster_path=media.poster_path,
                    )

            art = download_artwork(media, self._dest_dir, _log)
            poster_ok = art.get("poster") is not None
            fanart_ok = art.get("fanart") is not None

            nfo_path = create_nfo(media, self._dest_dir, _log)
            nfo_ok = nfo_path is not None

            _log("Scrape complete.")
        except Exception as exc:
            _log(f"Error: {exc}")

        self._msg_queue.put(("done", (poster_ok, fanart_ok, nfo_ok)))

    # --------------------------------------------------- queue poller
    def _poll_queue(self) -> None:
        try:
            while True:
                msg_type, payload = self._msg_queue.get_nowait()

                if msg_type == "log":
                    self.log_text.configure(state=tk.NORMAL)
                    self.log_text.insert(tk.END, payload + "\n")
                    self.log_text.see(tk.END)
                    self.log_text.configure(state=tk.DISABLED)

                elif msg_type == "done":
                    poster_ok, fanart_ok, nfo_ok = payload
                    self.progress_bar.stop()
                    self.status_label.configure(text="Complete")
                    self.scrape_btn.configure(state=tk.NORMAL)
                    self._running = False

                    self.poster_var.set(f"Poster: {'✅' if poster_ok else '❌'}")
                    self.fanart_var.set(f"Fanart: {'✅' if fanart_ok else '❌'}")
                    self.nfo_var.set(f"NFO: {'✅' if nfo_ok else '❌'}")

                    self.app.set_status("Scrape complete")

        except queue.Empty:
            pass

        if self._running:
            self.after(100, self._poll_queue)
