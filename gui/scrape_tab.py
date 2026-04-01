"""Built-in metadata scrape tab — downloads artwork and creates NFO files."""

from __future__ import annotations

import queue
import threading
import tkinter as tk

import customtkinter as ctk

from core.artwork import scrape_and_save


class ScrapeTab(ctk.CTkFrame):
    """Tab for scraping metadata, artwork, and NFO files via TMDb."""

    def __init__(self, parent, app) -> None:
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
        ctk.CTkLabel(self, text="Metadata Scraper", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(10, 0)
        )
        status_frame = ctk.CTkFrame(self)
        status_frame.pack(fill="x", padx=10, pady=(5, 5))

        info_row = ctk.CTkFrame(status_frame, fg_color="transparent")
        info_row.pack(fill="x", padx=10, pady=(5, 0))
        ctk.CTkLabel(info_row, text="Title:").pack(side="left", padx=(0, 5))
        self.title_var = tk.StringVar(value="(none)")
        ctk.CTkLabel(info_row, textvariable=self.title_var).pack(side="left")

        btn_row = ctk.CTkFrame(status_frame, fg_color="transparent")
        btn_row.pack(fill="x", padx=10, pady=5)
        self.scrape_btn = ctk.CTkButton(
            btn_row, text="Scrape & Download", command=self._on_scrape,
        )
        self.scrape_btn.pack(side="left", padx=(0, 5))

        self.progress_bar = ctk.CTkProgressBar(status_frame)
        self.progress_bar.pack(fill="x", padx=10, pady=(0, 5))
        self.progress_bar.configure(mode="indeterminate")
        self.progress_bar.set(0)

        self.status_label = ctk.CTkLabel(status_frame, text="Idle")
        self.status_label.pack(padx=10, pady=(0, 5))

        # -- Results section --
        ctk.CTkLabel(self, text="Results", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        results_frame = ctk.CTkFrame(self)
        results_frame.pack(fill="x", padx=10, pady=5)

        self.poster_var = tk.StringVar(value="Poster: —")
        self.fanart_var = tk.StringVar(value="Fanart: —")
        self.nfo_var = tk.StringVar(value="NFO: —")
        for var in (self.poster_var, self.fanart_var, self.nfo_var):
            ctk.CTkLabel(results_frame, textvariable=var).pack(
                anchor="w", padx=10, pady=2,
            )

        # -- Log section --
        ctk.CTkLabel(self, text="Log", font=ctk.CTkFont(weight="bold")).pack(
            anchor="w", padx=10, pady=(5, 0)
        )
        log_frame = ctk.CTkFrame(self)
        log_frame.pack(fill="both", expand=True, padx=10, pady=(5, 10))

        self.log_text = ctk.CTkTextbox(log_frame, height=200, wrap="word", state="disabled")
        self.log_text.pack(fill="both", expand=True, padx=10, pady=5)

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
        self.scrape_btn.configure(state="disabled")

        # Clear log
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

        # Reset results
        self.poster_var.set("Poster: —")
        self.fanart_var.set("Fanart: —")
        self.nfo_var.set("NFO: —")

        self.progress_bar.start()
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
                    self.log_text.configure(state="normal")
                    self.log_text.insert("end", payload + "\n")
                    self.log_text.see("end")
                    self.log_text.configure(state="disabled")

                elif msg_type == "done":
                    poster_ok, fanart_ok, nfo_ok = payload
                    self.progress_bar.stop()
                    self.status_label.configure(text="Complete")
                    self.scrape_btn.configure(state="normal")
                    self._running = False

                    self.poster_var.set(f"Poster: {'✅' if poster_ok else '❌'}")
                    self.fanart_var.set(f"Fanart: {'✅' if fanart_ok else '❌'}")
                    self.nfo_var.set(f"NFO: {'✅' if nfo_ok else '❌'}")

                    self.app.set_status("Scrape complete")

        except queue.Empty:
            pass

        if self._running:
            self.after(100, self._poll_queue)
