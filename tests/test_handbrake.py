from __future__ import annotations

import os
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import core.handbrake as handbrake
from core.handbrake import (
    HandBrakeError,
    HandBrakeNotFoundError,
    encode,
    get_handbrake_path,
    list_presets,
    scan_tracks,
)


class TestGetHandBrakePath(unittest.TestCase):
    @patch("core.handbrake.os.access", return_value=True)
    @patch("core.handbrake.os.path.isfile", return_value=True)
    @patch(
        "core.handbrake.load_config",
        return_value={"handbrake_path": "/usr/bin/HandBrakeCLI"},
    )
    def test_found(self, _mock_cfg, _mock_isfile, _mock_access):
        path = get_handbrake_path()
        self.assertEqual(path, "/usr/bin/HandBrakeCLI")

    @patch("core.handbrake.os.path.isfile", return_value=False)
    @patch(
        "core.handbrake.load_config",
        return_value={"handbrake_path": "/nonexistent/HandBrakeCLI"},
    )
    def test_not_found(self, _mock_cfg, _mock_isfile):
        with self.assertRaises(HandBrakeNotFoundError):
            get_handbrake_path()


class TestListPresets(unittest.TestCase):
    def setUp(self):
        # Clear the module-level preset cache before each test
        handbrake._cached_presets = None

    @patch("core.handbrake.get_handbrake_path", return_value="/usr/bin/HandBrakeCLI")
    @patch("core.handbrake.subprocess.run")
    def test_parses_presets(self, mock_run, _mock_path):
        mock_result = MagicMock()
        mock_result.stdout = (
            "  General/\n"
            "      + Very Fast 1080p30\n"
            "      + Fast 1080p30\n"
            "      + HQ 1080p30 Surround\n"
        )
        mock_result.stderr = ""
        mock_run.return_value = mock_result

        presets = list_presets()

        self.assertIn("Very Fast 1080p30", presets)
        self.assertIn("Fast 1080p30", presets)
        self.assertIn("HQ 1080p30 Surround", presets)
        self.assertEqual(len(presets), 3)


SCAN_STDERR = """\
+ audio tracks:
    + 1, English (AC3) (5.1 ch) (iso639-2: eng)
    + 2, Spanish (AAC) (2.0 ch) (iso639-2: spa)
+ subtitle tracks:
    + 1, English (PGS) (iso639-2: eng)
    + 2, French (SRT) (iso639-2: fre)
"""


class TestScanTracks(unittest.TestCase):
    @patch("core.handbrake.get_handbrake_path", return_value="/usr/bin/HandBrakeCLI")
    @patch("core.handbrake.subprocess.run")
    def test_parses_tracks(self, mock_run, _mock_path):
        mock_result = MagicMock()
        mock_result.stdout = ""
        mock_result.stderr = SCAN_STDERR
        mock_run.return_value = mock_result

        result = scan_tracks("/fake/input.mkv")

        self.assertIn("audio", result)
        self.assertIn("subtitles", result)
        self.assertEqual(len(result["audio"]), 2)
        self.assertEqual(result["audio"][0]["language"], "English")
        self.assertEqual(result["audio"][1]["language"], "Spanish")
        self.assertEqual(len(result["subtitles"]), 2)
        self.assertEqual(result["subtitles"][0]["language"], "English")
        self.assertEqual(result["subtitles"][1]["language"], "French")


class TestEncode(unittest.TestCase):
    @patch("core.handbrake.os.makedirs")
    @patch("core.handbrake.os.path.isfile", return_value=True)
    @patch("core.handbrake.get_handbrake_path", return_value="/usr/bin/HandBrakeCLI")
    @patch("core.handbrake.subprocess.Popen")
    def test_success(self, mock_popen, _mock_path, _mock_isfile, _mock_makedirs):
        mock_proc = MagicMock()
        # Simulate reading output char-by-char: return empty immediately to end
        mock_proc.stdout.read = MagicMock(return_value="")
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        result = encode("/fake/input.mkv", "/fake/output.mkv", "HQ 1080p30 Surround")

        self.assertEqual(result, "/fake/output.mkv")

    @patch("core.handbrake.os.makedirs")
    @patch("core.handbrake.get_handbrake_path", return_value="/usr/bin/HandBrakeCLI")
    @patch("core.handbrake.subprocess.Popen")
    def test_failure(self, mock_popen, _mock_path, _mock_makedirs):
        mock_proc = MagicMock()
        mock_proc.stdout.read = MagicMock(return_value="")
        mock_proc.poll = MagicMock(return_value=1)
        mock_proc.wait.return_value = 1
        mock_proc.returncode = 1
        mock_popen.return_value = mock_proc

        with self.assertRaises(HandBrakeError):
            encode("/fake/input.mkv", "/fake/output.mkv", "HQ 1080p30 Surround")


if __name__ == "__main__":
    unittest.main()
