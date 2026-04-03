"""Background job queue for the encode → organize → scrape pipeline."""

from __future__ import annotations

import logging
import os
import threading
import time
import weakref
from dataclasses import dataclass, field
from typing import Callable, Optional

log = logging.getLogger(__name__)

_MAX_FINISHED_JOBS = 50


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
    rip_elapsed: float = 0.0


class JobQueue:
    """Background job processor for encode → organize → scrape pipeline."""

    def __init__(self) -> None:
        self._jobs: list[Job] = []
        self._lock = threading.Lock()
        self._worker_thread: threading.Thread | None = None
        self._running = False
        self._current_proc: Optional[object] = None  # subprocess for abort
        self._callbacks: list[weakref.WeakMethod | weakref.ref] = []

    def add_job(self, disc_name: str, ripped_file: str, rip_elapsed: float = 0.0) -> Job:
        """Add a new job to the queue and start processing if not already running."""
        job = Job(
            id=f"job_{int(time.time() * 1000)}",
            disc_name=disc_name,
            ripped_file=ripped_file,
            rip_elapsed=rip_elapsed,
        )
        with self._lock:
            self._jobs.append(job)
        log.info("Job %s queued: %s (%s)", job.id, disc_name, ripped_file)
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
        """Register a callback via weak reference so it doesn't prevent GC."""
        if hasattr(callback, "__self__"):
            ref = weakref.WeakMethod(callback)
        else:
            ref = weakref.ref(callback)
        self._callbacks.append(ref)

    # -------------------------------------------------------------- internal

    def _notify(self) -> None:
        alive: list[weakref.WeakMethod | weakref.ref] = []
        for ref in self._callbacks:
            cb = ref()
            if cb is not None:
                try:
                    cb()
                except Exception:
                    pass
                alive.append(ref)
        self._callbacks = alive

    def _prune_finished(self) -> None:
        """Remove oldest finished jobs when the history exceeds the limit."""
        with self._lock:
            finished = [j for j in self._jobs if j.status in ("done", "failed")]
            excess = len(finished) - _MAX_FINISHED_JOBS
            if excess <= 0:
                return
            to_remove = set(id(j) for j in finished[:excess])
            self._jobs = [j for j in self._jobs if id(j) not in to_remove]

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
            self._prune_finished()

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
        from core.discord_notify import JobCard
        from core.macos_notify import notify as mac_notify

        config = load_config()
        nas_enabled = config.get("nas_upload_enabled", False)
        card = JobCard(job.disc_name, nas_enabled=nas_enabled)

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

        # Mark rip as already done
        rip_size = 0
        try:
            rip_size = os.path.getsize(job.ripped_file)
        except OSError:
            pass
        rip_detail = _human_size(rip_size)
        if job.rip_elapsed > 0:
            rip_detail += f" · {_human_time(job.rip_elapsed)}"
        card.finish("rip", detail=rip_detail)

        # Step 1: Encode
        job.status = "encoding"
        log.info("Job %s: encoding started (preset=%s)", job.id, config.get("default_preset", ""))
        job.progress = 0
        job.progress_text = "Encoding..."
        self._notify()

        card.start("encode")

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
            log.error("Job %s: encode failed: %s", job.id, exc)
            self._notify()
            card.fail("encode", detail=str(exc))
            mac_notify("AutoRipper — Failed", f"{job.disc_name}: Encode failed")
            return

        encode_elapsed = time.monotonic() - encode_start
        encoded_size = 0
        try:
            encoded_size = os.path.getsize(job.encoded_file)
        except OSError:
            pass

        card.finish(
            "encode",
            detail=f"{_human_size(rip_size)} → {_human_size(encoded_size)} · {preset} · {_human_time(encode_elapsed)}",
        )

        # Delete original rip to save space
        try:
            if os.path.isfile(job.ripped_file) and job.ripped_file != job.encoded_file:
                os.remove(job.ripped_file)
        except OSError:
            pass

        # Step 2: Organize
        job.status = "organizing"
        job.progress = 0
        job.progress_text = "Organizing..."
        self._notify()
        card.start("organize")

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
            log.error("Job %s: organize failed: %s", job.id, exc)
            self._notify()
            card.fail("organize", detail=str(exc))
            mac_notify("AutoRipper — Failed", f"{job.disc_name}: Organize failed")
            return

        card.finish("organize")

        # Step 3: Scrape metadata & artwork (non-critical)
        job.status = "scraping"
        job.progress = 0
        job.progress_text = "Downloading artwork & NFO..."
        self._notify()
        card.start("scrape")

        try:
            scrape_and_save(job.disc_name, os.path.dirname(job.organized_file))
            card.finish("scrape")
        except Exception:
            card.finish("scrape")  # non-critical

        # Step 4: Copy to NAS (optional)
        nas_path = ""
        if nas_enabled:
            import shutil
            media_type = config.get("default_media_type", "movie")
            if media_type == "movie":
                nas_dir = config.get("nas_movies_path", "")
            else:
                nas_dir = config.get("nas_tv_path", "")

            if nas_dir and os.path.isdir(nas_dir):
                job.status = "uploading"
                job.progress = 0
                job.progress_text = "Copying to NAS..."
                self._notify()
                card.start("nas")

                nas_start = time.monotonic()
                try:
                    # Copy the entire organized folder to NAS
                    src_dir = os.path.dirname(job.organized_file)
                    folder_name = os.path.basename(src_dir)
                    nas_dest = os.path.join(nas_dir, folder_name)
                    if os.path.exists(nas_dest):
                        shutil.rmtree(nas_dest)
                    shutil.copytree(src_dir, nas_dest)
                    nas_path = os.path.join(nas_dest, os.path.basename(job.organized_file))
                    job.progress_text = f"Copied to NAS: {nas_dest}"

                    # Clean up local files now that they're on the NAS
                    try:
                        shutil.rmtree(src_dir)
                    except OSError:
                        pass
                    nas_elapsed = time.monotonic() - nas_start
                    card.finish("nas", detail=f"{nas_dest} · {_human_time(nas_elapsed)}")
                except Exception as exc:
                    job.progress_text = f"NAS copy failed: {exc}"
                    card.fail("nas", detail=str(exc))
            else:
                card.skip("nas")
        else:
            card.skip("nas")

        # Done
        job.status = "done"
        job.progress = 100
        job.progress_text = "Complete"
        self._notify()
        total_elapsed = time.monotonic() - encode_start + job.rip_elapsed
        final_size = 0
        try:
            final_size = os.path.getsize(job.organized_file)
        except OSError:
            final_size = encoded_size
        log.info(
            "Job %s: complete — %s → %s in %s",
            job.id, _human_size(rip_size), _human_size(final_size), _human_time(total_elapsed),
        )
        card.complete(footer=f"Total: {_human_size(rip_size)} → {_human_size(final_size)} · {_human_time(total_elapsed)}")
        mac_notify("AutoRipper — Complete", f"{job.disc_name} · {_human_size(final_size)} · {_human_time(total_elapsed)}")
