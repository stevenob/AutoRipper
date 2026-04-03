from __future__ import annotations

import os
import sys
import time
import unittest
import weakref
from unittest.mock import MagicMock, patch, call

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.job_queue import Job, JobQueue, _MAX_FINISHED_JOBS


class TestJobDataclass(unittest.TestCase):
    def test_creation_with_required_fields(self):
        j = Job(id="job_1", disc_name="MOVIE", ripped_file="/path/rip.mkv")
        self.assertEqual(j.id, "job_1")
        self.assertEqual(j.disc_name, "MOVIE")
        self.assertEqual(j.ripped_file, "/path/rip.mkv")

    def test_defaults(self):
        j = Job(id="j", disc_name="D", ripped_file="f")
        self.assertEqual(j.encoded_file, "")
        self.assertEqual(j.organized_file, "")
        self.assertEqual(j.status, "queued")
        self.assertEqual(j.error, "")
        self.assertEqual(j.progress, 0)
        self.assertEqual(j.progress_text, "Queued")
        self.assertEqual(j.rip_elapsed, 0.0)

    def test_custom_fields(self):
        j = Job(
            id="job_2",
            disc_name="MOVIE",
            ripped_file="/rip.mkv",
            encoded_file="/enc.mkv",
            status="encoding",
            progress=50,
            progress_text="Encoding...",
            rip_elapsed=120.5,
        )
        self.assertEqual(j.encoded_file, "/enc.mkv")
        self.assertEqual(j.status, "encoding")
        self.assertEqual(j.progress, 50)
        self.assertEqual(j.rip_elapsed, 120.5)


class TestJobQueueAddJob(unittest.TestCase):
    @patch.object(JobQueue, "_ensure_worker")
    def test_creates_job_with_correct_fields(self, mock_worker):
        q = JobQueue()
        job = q.add_job("MY_DISC", "/path/title.mkv", rip_elapsed=60.0)
        self.assertIsInstance(job, Job)
        self.assertEqual(job.disc_name, "MY_DISC")
        self.assertEqual(job.ripped_file, "/path/title.mkv")
        self.assertEqual(job.rip_elapsed, 60.0)
        self.assertEqual(job.status, "queued")
        self.assertTrue(job.id.startswith("job_"))

    @patch.object(JobQueue, "_ensure_worker")
    def test_appends_to_jobs_list(self, mock_worker):
        q = JobQueue()
        q.add_job("A", "/a.mkv")
        q.add_job("B", "/b.mkv")
        self.assertEqual(len(q._jobs), 2)

    @patch.object(JobQueue, "_ensure_worker")
    def test_calls_ensure_worker(self, mock_worker):
        q = JobQueue()
        q.add_job("A", "/a.mkv")
        mock_worker.assert_called_once()


class TestJobQueueGetJobs(unittest.TestCase):
    @patch.object(JobQueue, "_ensure_worker")
    def test_returns_copy(self, mock_worker):
        q = JobQueue()
        q.add_job("A", "/a.mkv")
        jobs = q.get_jobs()
        self.assertEqual(len(jobs), 1)
        # Modifying the returned list should not affect internal list
        jobs.clear()
        self.assertEqual(len(q.get_jobs()), 1)

    @patch.object(JobQueue, "_ensure_worker")
    def test_empty_queue(self, mock_worker):
        q = JobQueue()
        self.assertEqual(q.get_jobs(), [])


class TestJobQueueOnUpdate(unittest.TestCase):
    @patch.object(JobQueue, "_ensure_worker")
    def test_callback_called_on_notify(self, mock_worker):
        q = JobQueue()
        cb = MagicMock()
        # Keep a strong reference so weakref stays alive
        q.on_update(cb)
        q._notify()
        cb.assert_called_once()

    @patch.object(JobQueue, "_ensure_worker")
    def test_dead_refs_pruned(self, mock_worker):
        q = JobQueue()

        class Holder:
            def callback(self):
                pass

        h = Holder()
        q.on_update(h.callback)
        self.assertEqual(len(q._callbacks), 1)
        del h
        q._notify()
        # Dead ref should have been pruned
        self.assertEqual(len(q._callbacks), 0)


class TestJobQueuePruneFinished(unittest.TestCase):
    @patch.object(JobQueue, "_ensure_worker")
    def test_keeps_active_jobs(self, mock_worker):
        q = JobQueue()
        for i in range(5):
            j = Job(id=f"j{i}", disc_name="D", ripped_file="f")
            j.status = "encoding"
            q._jobs.append(j)
        q._prune_finished()
        self.assertEqual(len(q._jobs), 5)

    @patch.object(JobQueue, "_ensure_worker")
    def test_removes_excess_finished(self, mock_worker):
        q = JobQueue()
        total = _MAX_FINISHED_JOBS + 10
        for i in range(total):
            j = Job(id=f"j{i}", disc_name="D", ripped_file="f")
            j.status = "done"
            q._jobs.append(j)
        q._prune_finished()
        self.assertEqual(len(q._jobs), _MAX_FINISHED_JOBS)

    @patch.object(JobQueue, "_ensure_worker")
    def test_does_not_prune_below_limit(self, mock_worker):
        q = JobQueue()
        for i in range(3):
            j = Job(id=f"j{i}", disc_name="D", ripped_file="f")
            j.status = "done"
            q._jobs.append(j)
        q._prune_finished()
        self.assertEqual(len(q._jobs), 3)

    @patch.object(JobQueue, "_ensure_worker")
    def test_preserves_active_among_finished(self, mock_worker):
        q = JobQueue()
        # Add excess finished + some active
        for i in range(_MAX_FINISHED_JOBS + 5):
            j = Job(id=f"done_{i}", disc_name="D", ripped_file="f")
            j.status = "done"
            q._jobs.append(j)
        active = Job(id="active_1", disc_name="D", ripped_file="f")
        active.status = "encoding"
        q._jobs.append(active)

        q._prune_finished()
        ids = [j.id for j in q._jobs]
        self.assertIn("active_1", ids)


class TestJobQueueNextQueued(unittest.TestCase):
    @patch.object(JobQueue, "_ensure_worker")
    def test_returns_first_queued(self, mock_worker):
        q = JobQueue()
        j1 = Job(id="j1", disc_name="D1", ripped_file="f1")
        j1.status = "done"
        j2 = Job(id="j2", disc_name="D2", ripped_file="f2")
        j2.status = "queued"
        j3 = Job(id="j3", disc_name="D3", ripped_file="f3")
        j3.status = "queued"
        q._jobs = [j1, j2, j3]

        result = q._next_queued()
        self.assertEqual(result.id, "j2")

    @patch.object(JobQueue, "_ensure_worker")
    def test_returns_none_when_no_queued(self, mock_worker):
        q = JobQueue()
        j = Job(id="j1", disc_name="D", ripped_file="f")
        j.status = "done"
        q._jobs = [j]
        self.assertIsNone(q._next_queued())

    @patch.object(JobQueue, "_ensure_worker")
    def test_returns_none_for_empty_queue(self, mock_worker):
        q = JobQueue()
        self.assertIsNone(q._next_queued())


if __name__ == "__main__":
    unittest.main()
