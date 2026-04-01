"""Queue tab — shows background job queue status."""

from __future__ import annotations

import queue
import tkinter as tk
from tkinter import ttk

from core.job_queue import JobQueue

_STATUS_ICONS = {
    "queued": "\u23f3 Queued",
    "encoding": "\U0001f504 Encoding",
    "organizing": "\U0001f4c2 Organizing",
    "scraping": "\U0001f50d Scraping",
    "done": "\u2705 Done",
    "failed": "\u274c Failed",
}


class QueueTab(ttk.Frame):
    """Tab displaying the background job queue."""

    def __init__(self, parent: tk.Widget, *, app: object, job_queue: JobQueue) -> None:
        super().__init__(parent)
        self.app = app
        self.job_queue = job_queue
        self._update_queue: queue.Queue[bool] = queue.Queue()

        self._build_ui()

        # Register for job-queue change notifications (called from worker thread)
        self.job_queue.on_update(self._on_job_update)

        # Start polling loop
        self.after(200, self._poll)

    # ------------------------------------------------------------------ UI

    def _build_ui(self) -> None:
        # Treeview for jobs
        columns = ("status", "title", "step", "progress")
        self.tree = ttk.Treeview(self, columns=columns, show="headings", selectmode="browse")
        self.tree.heading("status", text="Status")
        self.tree.heading("title", text="Title")
        self.tree.heading("step", text="Step")
        self.tree.heading("progress", text="Progress")

        self.tree.column("status", width=120, anchor=tk.W)
        self.tree.column("title", width=300, anchor=tk.W)
        self.tree.column("step", width=200, anchor=tk.W)
        self.tree.column("progress", width=80, anchor=tk.CENTER)

        scrollbar = ttk.Scrollbar(self, orient=tk.VERTICAL, command=self.tree.yview)
        self.tree.configure(yscrollcommand=scrollbar.set)

        self.tree.pack(side=tk.TOP, fill=tk.BOTH, expand=True, padx=10, pady=(10, 0))
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Bottom bar
        bottom = ttk.Frame(self)
        bottom.pack(fill=tk.X, padx=10, pady=10)

        self.abort_btn = ttk.Button(bottom, text="Abort Current", command=self._on_abort)
        self.abort_btn.pack(side=tk.LEFT)

        self.status_label = ttk.Label(bottom, text="Queue idle")
        self.status_label.pack(side=tk.LEFT, padx=(15, 0))

    # ------------------------------------------------------------------ callbacks

    def _on_job_update(self) -> None:
        """Called from the worker thread — enqueue a UI refresh."""
        self._update_queue.put(True)

    def _poll(self) -> None:
        """Check for update notifications and refresh the treeview."""
        refreshed = False
        try:
            while True:
                self._update_queue.get_nowait()
                refreshed = True
        except queue.Empty:
            pass

        if refreshed:
            self._refresh()

        self.after(200, self._poll)

    def _refresh(self) -> None:
        """Clear and repopulate the treeview with current job states."""
        self.tree.delete(*self.tree.get_children())
        jobs = self.job_queue.get_jobs()

        active = 0
        total = len(jobs)

        for job in jobs:
            status_text = _STATUS_ICONS.get(job.status, job.status)
            progress_text = f"{job.progress}%" if job.status not in ("queued", "done", "failed") else ""
            self.tree.insert(
                "",
                tk.END,
                iid=job.id,
                values=(status_text, job.disc_name, job.progress_text, progress_text),
            )
            if job.status not in ("done", "failed", "queued"):
                active += 1

        # Update status label
        done_count = sum(1 for j in jobs if j.status == "done")
        if active:
            self.status_label.configure(text=f"Processing job {done_count + 1} of {total}")
        elif total:
            self.status_label.configure(text=f"Queue idle — {done_count}/{total} complete")
        else:
            self.status_label.configure(text="Queue idle")

    def _on_abort(self) -> None:
        """Abort the currently running subprocess."""
        self.job_queue.abort_current()
