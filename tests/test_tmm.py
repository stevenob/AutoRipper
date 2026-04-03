from __future__ import annotations

import os
import sys
import unittest
from unittest.mock import MagicMock, patch, call, PropertyMock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.tmm import (
    TmmError,
    TmmNotFoundError,
    get_tmm_dir,
    run_tmm,
    scrape_and_rename,
    download_subtitles,
)


class TestGetTmmDir(unittest.TestCase):
    @patch("core.tmm.os.path.isfile", return_value=True)
    @patch("core.tmm.load_config", return_value={"tmm_path": "/opt/tmm"})
    def test_returns_dir_when_jar_exists(self, mock_cfg, mock_isfile):
        result = get_tmm_dir()
        self.assertEqual(result, "/opt/tmm")
        mock_isfile.assert_called_once_with("/opt/tmm/tmm.jar")

    @patch("core.tmm.os.path.isfile", return_value=False)
    @patch("core.tmm.load_config", return_value={"tmm_path": "/opt/tmm"})
    def test_raises_when_jar_missing(self, mock_cfg, mock_isfile):
        with self.assertRaises(TmmNotFoundError):
            get_tmm_dir()

    @patch("core.tmm.load_config", return_value={"tmm_path": ""})
    def test_raises_when_path_empty(self, mock_cfg):
        with self.assertRaises(TmmNotFoundError):
            get_tmm_dir()

    @patch("core.tmm.os.path.isfile", return_value=True)
    @patch("core.tmm.load_config", return_value={})
    def test_uses_default_path_when_not_configured(self, mock_cfg, mock_isfile):
        result = get_tmm_dir()
        self.assertIn("tinyMediaManager", result)


class TestRunTmm(unittest.TestCase):
    def _mock_proc(self, lines=None, returncode=0):
        proc = MagicMock()
        proc.stdout.readline = MagicMock(side_effect=(lines or []) + [""])
        proc.wait.return_value = None
        type(proc).returncode = PropertyMock(return_value=returncode)
        return proc

    @patch("core.tmm.subprocess.Popen")
    @patch("core.tmm.get_tmm_dir", return_value="/opt/tmm")
    def test_calls_popen_with_correct_args(self, mock_dir, mock_popen):
        mock_popen.return_value = self._mock_proc()
        run_tmm("movie", ["-u", "-n"])
        cmd = mock_popen.call_args[0][0]
        self.assertIn("/opt/tmm/jre/bin/java", cmd[0])
        self.assertIn("org.tinymediamanager.TinyMediaManager", cmd)
        self.assertIn("movie", cmd)
        self.assertIn("-u", cmd)
        self.assertIn("-n", cmd)

    @patch("core.tmm.subprocess.Popen")
    @patch("core.tmm.get_tmm_dir", return_value="/opt/tmm")
    def test_returns_true_on_success(self, mock_dir, mock_popen):
        mock_popen.return_value = self._mock_proc(returncode=0)
        self.assertTrue(run_tmm("movie", ["-u"]))

    @patch("core.tmm.subprocess.Popen")
    @patch("core.tmm.get_tmm_dir", return_value="/opt/tmm")
    def test_returns_false_on_failure(self, mock_dir, mock_popen):
        mock_popen.return_value = self._mock_proc(returncode=1)
        self.assertFalse(run_tmm("movie", ["-u"]))

    @patch("core.tmm.subprocess.Popen")
    @patch("core.tmm.get_tmm_dir", return_value="/opt/tmm")
    def test_passes_lines_to_log_callback(self, mock_dir, mock_popen):
        mock_popen.return_value = self._mock_proc(lines=["line1\n", "line2\n"])
        log = MagicMock()
        run_tmm("movie", ["-u"], log_callback=log)
        log.assert_any_call("line1")
        log.assert_any_call("line2")

    @patch("core.tmm.subprocess.Popen")
    @patch("core.tmm.get_tmm_dir", return_value="/opt/tmm")
    def test_passes_proc_to_proc_callback(self, mock_dir, mock_popen):
        proc = self._mock_proc()
        mock_popen.return_value = proc
        cb = MagicMock()
        run_tmm("movie", ["-u"], proc_callback=cb)
        cb.assert_called_once_with(proc)

    @patch("core.tmm.subprocess.Popen", side_effect=FileNotFoundError("no java"))
    @patch("core.tmm.get_tmm_dir", return_value="/opt/tmm")
    def test_raises_tmm_not_found_on_file_not_found(self, mock_dir, mock_popen):
        with self.assertRaises(TmmNotFoundError):
            run_tmm("movie", ["-u"])

    @patch("core.tmm.subprocess.Popen", side_effect=OSError("broken"))
    @patch("core.tmm.get_tmm_dir", return_value="/opt/tmm")
    def test_raises_tmm_error_on_os_error(self, mock_dir, mock_popen):
        with self.assertRaises(TmmError):
            run_tmm("movie", ["-u"])

    @patch("core.tmm.subprocess.Popen")
    @patch("core.tmm.get_tmm_dir", return_value="/opt/tmm")
    def test_skips_blank_lines(self, mock_dir, mock_popen):
        mock_popen.return_value = self._mock_proc(lines=["hello\n", "\n", "world\n"])
        log = MagicMock()
        run_tmm("movie", ["-u"], log_callback=log)
        self.assertEqual(log.call_count, 2)


class TestScrapeAndRename(unittest.TestCase):
    @patch("core.tmm.run_tmm", return_value=True)
    def test_calls_run_tmm_with_correct_flags(self, mock_run):
        result = scrape_and_rename("movie")
        mock_run.assert_called_once_with("movie", ["-u", "-n", "-r"], None, None)
        self.assertTrue(result)

    @patch("core.tmm.run_tmm", return_value=True)
    def test_passes_callbacks(self, mock_run):
        log_cb = MagicMock()
        proc_cb = MagicMock()
        scrape_and_rename("tvshow", log_callback=log_cb, proc_callback=proc_cb)
        mock_run.assert_called_once_with("tvshow", ["-u", "-n", "-r"], log_cb, proc_cb)


class TestDownloadSubtitles(unittest.TestCase):
    @patch("core.tmm.run_tmm", return_value=True)
    def test_calls_run_tmm_with_s_flag(self, mock_run):
        result = download_subtitles("movie")
        mock_run.assert_called_once_with("movie", ["-s"], None, None)
        self.assertTrue(result)

    @patch("core.tmm.run_tmm", return_value=True)
    def test_passes_callbacks(self, mock_run):
        log_cb = MagicMock()
        proc_cb = MagicMock()
        download_subtitles("tvshow", log_callback=log_cb, proc_callback=proc_cb)
        mock_run.assert_called_once_with("tvshow", ["-s"], log_cb, proc_cb)


if __name__ == "__main__":
    unittest.main()
