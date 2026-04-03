from __future__ import annotations

import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import MagicMock, patch, call

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.artwork import download_artwork, create_nfo, scrape_and_save, TMDB_IMAGE_BASE
from core.metadata import MediaResult


def _make_media(media_type="movie", poster_path="/poster.jpg"):
    return MediaResult(
        title="Test Movie",
        year=2024,
        media_type=media_type,
        tmdb_id=12345,
        overview="A test overview",
        poster_path=poster_path,
    )


class TestDownloadArtwork(unittest.TestCase):
    @patch("core.artwork._fetch_backdrop_path", return_value="/backdrop.jpg")
    @patch("core.artwork._download_image", return_value=True)
    def test_downloads_poster_and_fanart(self, mock_dl, mock_backdrop):
        with tempfile.TemporaryDirectory() as tmpdir:
            media = _make_media()
            result = download_artwork(media, tmpdir)
            self.assertEqual(mock_dl.call_count, 2)
            # Poster call
            poster_call = mock_dl.call_args_list[0]
            self.assertIn("/w500/poster.jpg", poster_call[0][0])
            self.assertTrue(poster_call[0][1].endswith("poster.jpg"))
            # Fanart call
            fanart_call = mock_dl.call_args_list[1]
            self.assertIn("/original/backdrop.jpg", fanart_call[0][0])
            self.assertTrue(fanart_call[0][1].endswith("fanart.jpg"))

    @patch("core.artwork._fetch_backdrop_path", return_value=None)
    @patch("core.artwork._download_image", return_value=True)
    def test_handles_missing_poster_path(self, mock_dl, mock_backdrop):
        with tempfile.TemporaryDirectory() as tmpdir:
            media = _make_media(poster_path=None)
            log = MagicMock()
            result = download_artwork(media, tmpdir, log_callback=log)
            self.assertIsNone(result["poster"])
            # Only fanart attempted (but backdrop is None too)
            mock_dl.assert_not_called()

    @patch("core.artwork._fetch_backdrop_path", return_value=None)
    @patch("core.artwork._download_image", return_value=False)
    def test_returns_none_paths_on_download_failure(self, mock_dl, mock_backdrop):
        with tempfile.TemporaryDirectory() as tmpdir:
            media = _make_media()
            result = download_artwork(media, tmpdir)
            self.assertIsNone(result["poster"])
            self.assertIsNone(result["fanart"])


class TestCreateNfo(unittest.TestCase):
    def test_creates_movie_nfo(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            media = _make_media()
            path = create_nfo(media, tmpdir)
            self.assertTrue(path.endswith("movie.nfo"))
            self.assertTrue(os.path.isfile(path))

            tree = ET.parse(path)
            root = tree.getroot()
            self.assertEqual(root.tag, "movie")
            self.assertEqual(root.find("title").text, "Test Movie")
            self.assertEqual(root.find("year").text, "2024")
            self.assertEqual(root.find("plot").text, "A test overview")
            self.assertEqual(root.find("tmdbid").text, "12345")

    def test_creates_tvshow_nfo(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            media = _make_media(media_type="tv")
            path = create_nfo(media, tmpdir)
            self.assertTrue(path.endswith("tvshow.nfo"))
            tree = ET.parse(path)
            root = tree.getroot()
            self.assertEqual(root.tag, "tvshow")

    def test_nfo_has_uniqueid(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            media = _make_media()
            path = create_nfo(media, tmpdir)
            tree = ET.parse(path)
            uid = tree.getroot().find("uniqueid")
            self.assertIsNotNone(uid)
            self.assertEqual(uid.get("type"), "tmdb")
            self.assertEqual(uid.text, "12345")

    def test_calls_log_callback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            media = _make_media()
            log = MagicMock()
            create_nfo(media, tmpdir, log_callback=log)
            log.assert_called_once()
            self.assertIn("movie.nfo", log.call_args[0][0])


class TestScrapeAndSave(unittest.TestCase):
    @patch("core.artwork.create_nfo")
    @patch("core.artwork.download_artwork")
    @patch("core.artwork.get_movie_details")
    @patch("core.artwork.search_media")
    def test_success_flow(self, mock_search, mock_details, mock_art, mock_nfo):
        media = _make_media()
        mock_search.return_value = [media]
        mock_details.return_value = media

        with tempfile.TemporaryDirectory() as tmpdir:
            result = scrape_and_save("Test Movie", tmpdir)
            self.assertTrue(result)
            mock_search.assert_called_once_with("Test Movie")
            mock_details.assert_called_once_with(12345)
            mock_art.assert_called_once()
            mock_nfo.assert_called_once()

    @patch("core.artwork.search_media", return_value=[])
    def test_returns_false_when_no_results(self, mock_search):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = scrape_and_save("Unknown Movie", tmpdir)
            self.assertFalse(result)

    @patch("core.artwork.create_nfo")
    @patch("core.artwork.download_artwork")
    @patch("core.artwork.get_tv_details")
    @patch("core.artwork.search_media")
    def test_tv_flow(self, mock_search, mock_tv_details, mock_art, mock_nfo):
        media = _make_media(media_type="tv")
        mock_search.return_value = [media]
        mock_tv_details.return_value = {"title": "Test Show", "year": 2024}

        with tempfile.TemporaryDirectory() as tmpdir:
            result = scrape_and_save("Test Show", tmpdir)
            self.assertTrue(result)
            mock_tv_details.assert_called_once_with(12345)

    @patch("core.artwork.create_nfo")
    @patch("core.artwork.download_artwork")
    @patch("core.artwork.get_movie_details", return_value=None)
    @patch("core.artwork.search_media")
    def test_proceeds_when_details_returns_none(self, mock_search, mock_details, mock_art, mock_nfo):
        media = _make_media()
        mock_search.return_value = [media]
        with tempfile.TemporaryDirectory() as tmpdir:
            result = scrape_and_save("Movie", tmpdir)
            self.assertTrue(result)
            # Should still call download_artwork with original media
            mock_art.assert_called_once()


if __name__ == "__main__":
    unittest.main()
