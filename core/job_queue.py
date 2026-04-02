"""Background job queue for the encode → organize → scrape pipeline."""

from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, Optional


@dataclass
class Job:
    """Represents a single ripped file going through the post-rip pipeline."""

    id: str
    disc_name: str
    ripped_file: str
    encoded_file: str = ""
    organized_file: str = ""
    status: str = "queued"
    error: str = ""
    progress: int = 0
    progress_text: str = "Queued"


class JobQueue:
    """Background job processor for encode → organize → scrape pipeline."""

    def __init__(self) -> None:
        self._jobs: list[Job] = []
        self._lock = threading.Lock()
        self._worker_thread: threading.Thread | None = None
        self._running = False
        self._current_proc: Optional[object] = None  # subprocess for abort
        self._callbacks: list[Callable] = []  # GUI update callbacks

    def add_job(self, disc_name: str, ripped_file: str) -> Job:
        """Add a new job to the queue and start processing if not already running."""
        job = Job(
            id=f"job_{int(time.time() * 1000)}",
            disc_name=disc_name,
            ripped_file=ripped_file,
        )
        with self._lock:
            self._jobs.append(job)
        self._ensure_worker()
        self._notify()
        return job

    def get_jobs(self) -> list[Job]:
        """Return a snapshot of current jobs."""
        with self._lock:
            return list(self._jobs)

    def abort_current(self) -> None:
        """Kill the currently running subprocess."""
        proc = self._current_proc
        if proc is not None and hasattr(proc, "poll") and proc.poll() is None:
            proc.kill()

    def on_update(self, callback: Callable) -> None:
        """Register a callback to be called when job state changes."""
        self._callbacks.append(callback)

    # -------------------------------------------------------------- internal

    def _notify(self) -> None:
        for cb in self._callbacks:
            try:
                cb()
            except Exception:
                pass

    def _ensure_worker(self) -> None:
        if self._running:
            return
        self._running = True
        self._worker_thread = threading.Thread(target=self._process_loop, daemon=True)
        self._worker_thread.start()

    def _process_loop(self) -> None:
        while True:
            job = self._next_queued()
            if not job:
                self._running = False
                return
            self._process_job(job)

    def _next_queued(self) -> Job | None:
        with self._lock:
            for j in self._jobs:
                if j.status == "queued":
                    return j
        return None

    def _process_job(self, job: Job) -> None:
        """Run encode → organize → scrape for a single job."""
        from config import load_config
        from core.handbrake import encode
        from core.organizer import build_movie_path, organize_file, clean_filename
        from core.metadata import search_media
        from core.artwork import scrape_and_save
        from core.discord_notify import notify_info, notify_progress, notify_success, notify_error

        config = load_config()

        def _human_size(size_bytes):
            for unit in ("B", "KB", "MB", "GB", "TB"):
                if abs(size_bytes) < 1024:
                    return f"{size_bytes:.1f} {unit}"
                size_bytes /= 1024
            return f"{size_bytes:.1f} PB"

        def _human_time(seconds):
            m, s = divmod(int(seconds), 60)
            h, m = divmod(m, 60)
            if h > 0:
                return f"{h}h{m:02d}m{s:02d}s"
            return f"{m}m{s:02d}s"

        # Step 1: Encode
        job.status = "encoding"
        job.progress = 0
        job.progress_text = "Encoding..."
        self._notify()

        rip_size = 0
        try:
            rip_size = os.path.getsize(job.ripped_file)
        except OSError:
            pass
        notify_info(f"🎬 Encoding: {job.disc_name}\n📁 Source: {_human_size(rip_size)}")

        encode_start = time.monotonic()
        try:
            base, _ext = os.path.splitext(job.ripped_file)
            output_path = base + "_encoded.mkv"
            preset = config.get("default_preset", "HQ 1080p30 Surround")

            def _progress_cb(percent: int, msg: str) -> None:
                job.progress = percent
                job.progress_text = msg
                self._notify()

            def _proc_cb(proc: object) -> None:
                self._current_proc = proc

            job.encoded_file = encode(
                job.ripped_file,
                output_path,
                preset,
                progress_callback=_progress_cb,
                proc_callback=_proc_cb,
            )
        except Exception as exc:
            job.status = "failed"
            job.error = f"Encode failed: {exc}"
            job.progress_text = "Encode failed"
            self._notify()
            notify_error(f"🎬 {job.disc_name}\n❌ {job.error}")
            return

        encode_elapsed = time.monotonic() - encode_start
        encoded_size = 0
        try:
            encoded_size = os.path.getsize(job.encoded_file)
        except OSError:
            pass

        # Step 2: Organize
        job.status = "organizing"
        job.progress = 0
        job.progress_text = "Organizing..."
        self._notify()
        notify_progress(
            f"📂 Organizing: {job.disc_name}\n"
            f"🔄 Encoded: {_human_size(rip_size)} → {_human_size(encoded_size)} in {_human_time(encode_elapsed)}"
        )

        try:
            output_dir = config.get("output_dir", "")
            if job.disc_name and output_dir:
                try:
                    results = search_media(job.disc_name)
                    if results:
                        title = results[0].title
                        year = results[0].year
                        dest = build_movie_path(output_dir, title, year)
                    else:
                        dest = build_movie_path(output_dir, clean_filename(job.disc_name))
                except Exception:
                    dest = build_movie_path(output_dir, clean_filename(job.disc_name))

                job.organized_file = organize_file(job.encoded_file, dest)
            else:
                job.organized_file = job.encoded_file

            job.progress_text = f"Organized: {os.path.basename(job.organized_file)}"
        except Exception as exc:
            job.status = "failed"
            job.error = f"Organize failed: {exc}"
            job.progress_text = "Organize failed"
            self._notify()
            notify_error(f"🎬 {job.disc_name}\n❌ {job.error}")
            return

        # Step 3: Scrape metadata & artwork (non-critical)
        job.status = "scraping"
        job.progress = 0
        job.progress_text = "Downloading artwork & NFO..."
        self._notify()

        try:
            scrape_and_save(job.disc_name, os.path.dirname(job.organized_file))
        except Exception:
            pass  # scrape failure is non-critical

        # Done
        job.status = "done"
        job.progress = 100
        job.progress_text = "Complete"
        self._notify()
        total_elapsed = time.monotonic() - encode_start
        final_size = 0
        try:
            final_size = os.path.getsize(job.organized_file)
        except OSError:
            final_size = encoded_size
        notify_success(
            f"🎬 {job.disc_name}\n"
            f"📁 {_human_size(rip_size)} → {_human_size(final_size)}\n"
            f"⏱️ {_human_time(total_elapsed)}\n"
            f"📂 {job.organized_file}"
        )
