from __future__ import annotations

import os
import sys
import unittest
from unittest.mock import MagicMock, patch, call

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.disc import TitleInfo, DiscInfo


class TestTitleInfo(unittest.TestCase):
    def test_creation_with_all_fields(self):
        t = TitleInfo(
            id=1,
            name="Main Feature",
            duration="1:30:00",
            size_bytes=4_000_000_000,
            chapters=12,
            file_output="title_01.mkv",
            resolution="1920x1080",
        )
        self.assertEqual(t.id, 1)
        self.assertEqual(t.name, "Main Feature")
        self.assertEqual(t.duration, "1:30:00")
        self.assertEqual(t.size_bytes, 4_000_000_000)
        self.assertEqual(t.chapters, 12)
        self.assertEqual(t.file_output, "title_01.mkv")
        self.assertEqual(t.resolution, "1920x1080")

    def test_default_resolution_is_empty_string(self):
        t = TitleInfo(
            id=0,
            name="Bonus",
            duration="0:05:00",
            size_bytes=100_000,
            chapters=1,
            file_output="bonus.mkv",
        )
        self.assertEqual(t.resolution, "")

    def test_equality(self):
        a = TitleInfo(0, "A", "0:01", 100, 1, "a.mkv", "720x480")
        b = TitleInfo(0, "A", "0:01", 100, 1, "a.mkv", "720x480")
        self.assertEqual(a, b)

    def test_inequality(self):
        a = TitleInfo(0, "A", "0:01", 100, 1, "a.mkv")
        b = TitleInfo(1, "A", "0:01", 100, 1, "a.mkv")
        self.assertNotEqual(a, b)


class TestDiscInfo(unittest.TestCase):
    def test_creation(self):
        d = DiscInfo(name="MY_MOVIE", type="bluray")
        self.assertEqual(d.name, "MY_MOVIE")
        self.assertEqual(d.type, "bluray")

    def test_default_titles_is_empty_list(self):
        d = DiscInfo(name="DISC", type="dvd")
        self.assertEqual(d.titles, [])

    def test_default_titles_are_independent(self):
        d1 = DiscInfo(name="D1", type="dvd")
        d2 = DiscInfo(name="D2", type="dvd")
        d1.titles.append(
            TitleInfo(0, "T", "0:01", 1, 1, "t.mkv")
        )
        self.assertEqual(len(d2.titles), 0)

    def test_creation_with_titles(self):
        titles = [
            TitleInfo(0, "Main", "1:30:00", 4_000_000_000, 20, "main.mkv", "1920x1080"),
            TitleInfo(1, "Extras", "0:10:00", 500_000_000, 1, "extras.mkv"),
        ]
        d = DiscInfo(name="MOVIE", type="bluray", titles=titles)
        self.assertEqual(len(d.titles), 2)
        self.assertEqual(d.titles[0].name, "Main")
        self.assertEqual(d.titles[1].resolution, "")

    def test_adding_titles(self):
        d = DiscInfo(name="MOVIE", type="dvd")
        t = TitleInfo(0, "Title", "0:30:00", 1_000_000, 5, "t.mkv")
        d.titles.append(t)
        self.assertEqual(len(d.titles), 1)
        self.assertIs(d.titles[0], t)


if __name__ == "__main__":
    unittest.main()
