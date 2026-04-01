from __future__ import annotations

import os
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.metadata import (
    EpisodeInfo,
    MediaResult,
    clean_disc_name,
    get_movie_details,
    get_season_episodes,
    get_tv_details,
    search_media,
)


class TestCleanDiscName(unittest.TestCase):
    def test_underscores_to_spaces(self):
        self.assertEqual(clean_disc_name("MY_MOVIE"), "My Movie")

    def test_strips_disc_identifier(self):
        result = clean_disc_name("MY_MOVIE_DISC_1")
        self.assertNotIn("DISC", result.upper())
        self.assertIn("My Movie", result)

    def test_strips_bd(self):
        result = clean_disc_name("SOME_TITLE_BD")
        self.assertNotIn("BD", result.upper().split())

    def test_strips_resolution(self):
        result = clean_disc_name("TITLE_1080p")
        self.assertNotIn("1080p", result.lower())

    def test_strips_codec_tags(self):
        result = clean_disc_name("TITLE_HEVC_HDR")
        self.assertNotIn("HEVC", result.upper())
        self.assertNotIn("HDR", result.upper())


class TestSearchMedia(unittest.TestCase):
    @patch("core.metadata.load_config", return_value={"tmdb_api_key": "test-key"})
    @patch("core.metadata.requests.get")
    def test_success(self, mock_get, _mock_cfg):
        mock_resp = MagicMock()
        mock_resp.raise_for_status = MagicMock()
        mock_resp.json.return_value = {
            "results": [
                {
                    "media_type": "movie",
                    "title": "Inception",
                    "release_date": "2010-07-16",
                    "id": 27205,
                    "overview": "A mind-bending thriller.",
                    "poster_path": "/poster.jpg",
                },
            ],
        }
        mock_get.return_value = mock_resp

        results = search_media("inception")

        self.assertEqual(len(results), 1)
        self.assertIsInstance(results[0], MediaResult)
        self.assertEqual(results[0].title, "Inception")
        self.assertEqual(results[0].year, 2010)
        self.assertEqual(results[0].media_type, "movie")
        self.assertEqual(results[0].tmdb_id, 27205)

    @patch("core.metadata.load_config", return_value={"tmdb_api_key": ""})
    def test_no_api_key(self, _mock_cfg):
        results = search_media("anything")
        self.assertEqual(results, [])

    @patch("core.metadata.load_config", return_value={"tmdb_api_key": "test-key"})
    @patch("core.metadata.requests.get", side_effect=Exception("network error"))
    def test_api_error(self, _mock_get, _mock_cfg):
        results = search_media("anything")
        self.assertEqual(results, [])


class TestGetMovieDetails(unittest.TestCase):
    @patch("core.metadata.load_config", return_value={"tmdb_api_key": "test-key"})
    @patch("core.metadata.requests.get")
    def test_success(self, mock_get, _mock_cfg):
        mock_resp = MagicMock()
        mock_resp.raise_for_status = MagicMock()
        mock_resp.json.return_value = {
            "title": "Inception",
            "release_date": "2010-07-16",
            "id": 27205,
            "overview": "A mind-bending thriller.",
            "poster_path": "/poster.jpg",
        }
        mock_get.return_value = mock_resp

        result = get_movie_details(27205)

        self.assertIsNotNone(result)
        self.assertIsInstance(result, MediaResult)
        self.assertEqual(result.title, "Inception")
        self.assertEqual(result.year, 2010)
        self.assertEqual(result.media_type, "movie")


class TestGetTvDetails(unittest.TestCase):
    @patch("core.metadata.load_config", return_value={"tmdb_api_key": "test-key"})
    @patch("core.metadata.requests.get")
    def test_success(self, mock_get, _mock_cfg):
        mock_resp = MagicMock()
        mock_resp.raise_for_status = MagicMock()
        mock_resp.json.return_value = {
            "name": "Breaking Bad",
            "first_air_date": "2008-01-20",
            "number_of_seasons": 5,
            "seasons": [{"season_number": 1}],
        }
        mock_get.return_value = mock_resp

        result = get_tv_details(1396)

        self.assertIsNotNone(result)
        self.assertIsInstance(result, dict)
        self.assertEqual(result["title"], "Breaking Bad")
        self.assertEqual(result["year"], 2008)
        self.assertEqual(result["number_of_seasons"], 5)
        self.assertIn("seasons", result)


class TestGetSeasonEpisodes(unittest.TestCase):
    @patch("core.metadata.load_config", return_value={"tmdb_api_key": "test-key"})
    @patch("core.metadata.requests.get")
    def test_success(self, mock_get, _mock_cfg):
        mock_resp = MagicMock()
        mock_resp.raise_for_status = MagicMock()
        mock_resp.json.return_value = {
            "episodes": [
                {"season_number": 1, "episode_number": 1, "name": "Pilot"},
                {"season_number": 1, "episode_number": 2, "name": "Cat's in the Bag..."},
            ],
        }
        mock_get.return_value = mock_resp

        episodes = get_season_episodes(1396, 1)

        self.assertEqual(len(episodes), 2)
        self.assertIsInstance(episodes[0], EpisodeInfo)
        self.assertEqual(episodes[0].name, "Pilot")
        self.assertEqual(episodes[1].episode_number, 2)


if __name__ == "__main__":
    unittest.main()
