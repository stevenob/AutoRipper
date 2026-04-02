from __future__ import annotations

import os
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.makemkv import (
    DiscNotFoundError,
    MakeMKVNotFoundError,
    RipError,
    _parse_size_to_bytes,
    get_makemkv_path,
    rip_title,
    scan_disc,
)


class TestGetMakeMKVPath(unittest.TestCase):
    @patch("core.makemkv.os.access", return_value=True)
    @patch("core.makemkv.os.path.isfile", return_value=True)
    @patch(
        "core.makemkv.load_config",
        return_value={"makemkv_path": "/usr/bin/makemkvcon"},
    )
    def test_found(self, _mock_cfg, _mock_isfile, _mock_access):
        path = get_makemkv_path()
        self.assertEqual(path, "/usr/bin/makemkvcon")

    @patch("core.makemkv.os.path.isfile", return_value=False)
    @patch(
        "core.makemkv.load_config",
        return_value={"makemkv_path": "/nonexistent/makemkvcon"},
    )
    def test_not_found(self, _mock_cfg, _mock_isfile):
        with self.assertRaises(MakeMKVNotFoundError):
            get_makemkv_path()


SCAN_OUTPUT = """\
CINFO:1,6209,"Blu-ray disc"
CINFO:2,0,"Test Movie"
TINFO:0,2,0,"Test Movie"
TINFO:0,8,0,"20"
TINFO:0,9,0,"2:08:17"
TINFO:0,10,0,"31.1 GB"
TINFO:0,27,0,"test_t00.mkv"
SINFO:0,0,19,0,"1920x1080"
"""

SCAN_OUTPUT_DVD = """\
CINFO:1,6209,"DVD disc"
CINFO:2,0,"DVD Movie"
TINFO:0,2,0,"DVD Movie"
TINFO:0,8,0,"12"
TINFO:0,9,0,"1:30:00"
TINFO:0,10,0,"4.7 GB"
TINFO:0,27,0,"dvd_t00.mkv"
SINFO:0,0,19,0,"720x480"
"""

SCAN_OUTPUT_4K = """\
CINFO:1,6209,"Blu-ray disc"
CINFO:2,0,"4K Movie"
TINFO:0,2,0,"4K Movie"
TINFO:0,8,0,"24"
TINFO:0,9,0,"2:30:00"
TINFO:0,10,0,"60.0 GB"
TINFO:0,27,0,"4k_t00.mkv"
SINFO:0,0,19,0,"3840x2160"
"""

SCAN_OUTPUT_MULTI_TITLE = """\
CINFO:1,6209,"Blu-ray disc"
CINFO:2,0,"Multi Title Disc"
TINFO:0,2,0,"Main Feature"
TINFO:0,8,0,"28"
TINFO:0,9,0,"2:15:30"
TINFO:0,10,0,"35.0 GB"
TINFO:0,27,0,"main_t00.mkv"
SINFO:0,0,19,0,"1920x1080"
TINFO:1,2,0,"Behind the Scenes"
TINFO:1,8,0,"5"
TINFO:1,9,0,"0:25:00"
TINFO:1,10,0,"2.1 GB"
TINFO:1,27,0,"bonus_t01.mkv"
SINFO:1,0,19,0,"1920x1080"
TINFO:2,2,0,"Trailer"
TINFO:2,8,0,"1"
TINFO:2,9,0,"0:02:30"
TINFO:2,10,0,"200.0 MB"
TINFO:2,27,0,"trailer_t02.mkv"
SINFO:2,0,19,0,"1920x1080"
TINFO:3,2,0,"Deleted Scenes"
TINFO:3,8,0,"3"
TINFO:3,9,0,"0:08:45"
TINFO:3,10,0,"800.0 MB"
TINFO:3,27,0,"deleted_t03.mkv"
SINFO:3,0,19,0,"1920x1080"
"""


class TestScanDisc(unittest.TestCase):
    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_parses_output(self, mock_popen, _mock_path):
        lines = [line + "\n" for line in SCAN_OUTPUT.strip().splitlines()]
        lines.append("")  # sentinel for readline loop

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        # poll is only called when readline returns ""; return 0 to break
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        disc = scan_disc()

        self.assertEqual(disc.name, "Test Movie")
        self.assertEqual(disc.type, "bluray")
        self.assertEqual(len(disc.titles), 1)

        title = disc.titles[0]
        self.assertEqual(title.id, 0)
        self.assertEqual(title.name, "Test Movie")
        self.assertEqual(title.duration, "2:08:17")
        self.assertEqual(title.chapters, 20)
        self.assertEqual(title.file_output, "test_t00.mkv")
        self.assertGreater(title.size_bytes, 0)
        self.assertEqual(title.resolution, "1920x1080")

    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_dvd_480p_resolution(self, mock_popen, _mock_path):
        lines = [line + "\n" for line in SCAN_OUTPUT_DVD.strip().splitlines()]
        lines.append("")

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        disc = scan_disc()

        self.assertEqual(disc.name, "DVD Movie")
        self.assertEqual(disc.type, "dvd")
        self.assertEqual(disc.titles[0].resolution, "720x480")

    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_4k_uhd_resolution(self, mock_popen, _mock_path):
        lines = [line + "\n" for line in SCAN_OUTPUT_4K.strip().splitlines()]
        lines.append("")

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        disc = scan_disc()

        self.assertEqual(disc.name, "4K Movie")
        self.assertEqual(disc.type, "bluray")
        self.assertEqual(disc.titles[0].resolution, "3840x2160")

    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_no_disc(self, mock_popen, _mock_path):
        lines = ['MSG:5010,0,0,"no disc inserted",""\n', ""]

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        with self.assertRaises(DiscNotFoundError):
            scan_disc()

    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_multi_title_disc(self, mock_popen, _mock_path):
        """Multi-title disc parses all titles with correct attributes."""
        lines = [line + "\n" for line in SCAN_OUTPUT_MULTI_TITLE.strip().splitlines()]
        lines.append("")

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        disc = scan_disc()

        self.assertEqual(disc.name, "Multi Title Disc")
        self.assertEqual(len(disc.titles), 4)
        self.assertEqual(disc.titles[0].name, "Main Feature")
        self.assertEqual(disc.titles[1].name, "Behind the Scenes")
        self.assertEqual(disc.titles[2].name, "Trailer")
        self.assertEqual(disc.titles[3].name, "Deleted Scenes")

    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_largest_title_is_main_feature(self, mock_popen, _mock_path):
        """The largest title by size should be the main feature."""
        lines = [line + "\n" for line in SCAN_OUTPUT_MULTI_TITLE.strip().splitlines()]
        lines.append("")

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        disc = scan_disc()

        largest = max(disc.titles, key=lambda t: t.size_bytes)
        self.assertEqual(largest.name, "Main Feature")
        self.assertEqual(largest.id, 0)
        self.assertGreater(largest.size_bytes, 30 * 1024**3)

    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_all_titles_have_resolution(self, mock_popen, _mock_path):
        """All titles in a multi-title scan should have resolution set."""
        lines = [line + "\n" for line in SCAN_OUTPUT_MULTI_TITLE.strip().splitlines()]
        lines.append("")

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        disc = scan_disc()

        for t in disc.titles:
            self.assertEqual(t.resolution, "1920x1080", f"Title {t.id} missing resolution")

    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_min_duration_filter(self, mock_popen, _mock_path):
        """Titles can be filtered by minimum duration in the GUI."""
        lines = [line + "\n" for line in SCAN_OUTPUT_MULTI_TITLE.strip().splitlines()]
        lines.append("")

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        disc = scan_disc()

        # Import helper from rip_tab
        from gui.rip_tab import _duration_to_secs

        # Filter at 10 minutes (600s) — should keep Main Feature and Behind the Scenes
        filtered = [t for t in disc.titles if _duration_to_secs(t.duration) >= 600]
        self.assertEqual(len(filtered), 2)
        self.assertEqual(filtered[0].name, "Main Feature")
        self.assertEqual(filtered[1].name, "Behind the Scenes")

        # Filter at 1 hour (3600s) — should keep only Main Feature
        filtered_1h = [t for t in disc.titles if _duration_to_secs(t.duration) >= 3600]
        self.assertEqual(len(filtered_1h), 1)
        self.assertEqual(filtered_1h[0].name, "Main Feature")

    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_log_callback_receives_lines(self, mock_popen, _mock_path):
        """Log callback should receive all output lines during scan."""
        lines = [line + "\n" for line in SCAN_OUTPUT.strip().splitlines()]
        lines.append("")

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        logged = []
        scan_disc(log_callback=logged.append)

        self.assertGreater(len(logged), 0)
        self.assertTrue(any("Test Movie" in line for line in logged))


class TestRipTitle(unittest.TestCase):
    @patch("core.makemkv.os.makedirs")
    @patch("core.makemkv.os.path.isfile", return_value=True)
    @patch("core.makemkv.os.listdir", return_value=["title_t00.mkv"])
    @patch("core.makemkv.get_makemkv_path", return_value="/usr/bin/makemkvcon")
    @patch("core.makemkv.subprocess.Popen")
    def test_success(self, mock_popen, _mock_path, _mock_listdir, _mock_isfile, _mock_makedirs):
        output_dir = "/fake/output"
        lines = [
            'PRGV:50,100,100\n',
            f'MSG:0,0,0,"MKV file {output_dir}/title_t00.mkv written",""\n',
            "",
        ]

        mock_proc = MagicMock()
        mock_proc.stdout.readline = MagicMock(side_effect=lines)
        mock_proc.poll = MagicMock(return_value=0)
        mock_proc.wait.return_value = 0
        mock_proc.returncode = 0
        mock_popen.return_value = mock_proc

        result = rip_title(0, output_dir)

        self.assertTrue(result.endswith(".mkv"))


class TestParseSizeToBytes(unittest.TestCase):
    def test_gb(self):
        self.assertEqual(_parse_size_to_bytes("1 GB"), 1024**3)

    def test_mb(self):
        self.assertEqual(_parse_size_to_bytes("1 MB"), 1024**2)

    def test_kb(self):
        self.assertEqual(_parse_size_to_bytes("1 KB"), 1024)

    def test_fractional_gb(self):
        self.assertEqual(_parse_size_to_bytes("4.7 GB"), int(4.7 * 1024**3))

    def test_invalid(self):
        self.assertEqual(_parse_size_to_bytes("unknown"), 0)


if __name__ == "__main__":
    unittest.main()
