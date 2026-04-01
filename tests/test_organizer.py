from __future__ import annotations

import os
import sys
import tempfile
import unittest

# Ensure the project root is on the path so ``from core.organizer import …`` works.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.organizer import (
    build_movie_path,
    build_tv_path,
    clean_filename,
    organize_file,
    preview_organization,
)


class TestCleanFilename(unittest.TestCase):
    def test_strips_illegal_chars(self):
        self.assertEqual(clean_filename('Movie: The "Return" <2>'), "Movie The Return 2")

    def test_strips_all_illegal_chars(self):
        for ch in r'/\:*?"<>|':
            self.assertNotIn(ch, clean_filename(f"a{ch}b"))

    def test_normalizes_whitespace(self):
        self.assertEqual(clean_filename("hello   world"), "hello world")

    def test_strips_leading_trailing(self):
        self.assertEqual(clean_filename("  hi  "), "hi")


class TestBuildMoviePath(unittest.TestCase):
    def test_with_year(self):
        result = build_movie_path("/out", "Test Movie", 2024)
        self.assertEqual(result, "/out/Test Movie (2024)/Test Movie (2024).mkv")

    def test_no_year(self):
        result = build_movie_path("/out", "Test Movie")
        self.assertEqual(result, "/out/Test Movie/Test Movie.mkv")


class TestBuildTvPath(unittest.TestCase):
    def test_basic(self):
        result = build_tv_path("/out", "Show Name", season=1, episode=3)
        self.assertEqual(
            result, "/out/Show Name/Season 01/Show Name - S01E03.mkv"
        )

    def test_with_episode_name(self):
        result = build_tv_path(
            "/out", "Show Name", season=2, episode=5, episode_name="Pilot"
        )
        self.assertEqual(
            result,
            "/out/Show Name/Season 02/Show Name - S02E05 - Pilot.mkv",
        )


class TestOrganizeFile(unittest.TestCase):
    def test_moves_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            src = os.path.join(tmpdir, "source.mkv")
            with open(src, "w") as f:
                f.write("data")

            dest = os.path.join(tmpdir, "dest", "movie.mkv")
            result = organize_file(src, dest)

            self.assertEqual(result, dest)
            self.assertTrue(os.path.isfile(dest))
            self.assertFalse(os.path.exists(src))

    def test_duplicate_adds_suffix(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            dest_dir = os.path.join(tmpdir, "dest")
            os.makedirs(dest_dir)

            # Create an existing file at the destination
            dest = os.path.join(dest_dir, "movie.mkv")
            with open(dest, "w") as f:
                f.write("existing")

            src = os.path.join(tmpdir, "source.mkv")
            with open(src, "w") as f:
                f.write("new")

            result = organize_file(src, dest)

            expected = os.path.join(dest_dir, "movie (2).mkv")
            self.assertEqual(result, expected)
            self.assertTrue(os.path.isfile(expected))


class TestPreviewOrganization(unittest.TestCase):
    def test_returned_keys(self):
        result = preview_organization("/a/source.mkv", "/b/dest/movie.mkv")
        self.assertIn("source", result)
        self.assertIn("destination", result)
        self.assertIn("directory", result)
        self.assertIn("filename", result)
        self.assertIn("exists", result)
        self.assertEqual(result["source"], "/a/source.mkv")
        self.assertEqual(result["destination"], "/b/dest/movie.mkv")
        self.assertEqual(result["filename"], "movie.mkv")


if __name__ == "__main__":
    unittest.main()
