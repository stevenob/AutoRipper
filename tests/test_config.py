from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import config


class TestLoadConfigDefaults(unittest.TestCase):
    def setUp(self):
        config._cache = None

    @patch("config.os.path.exists", return_value=False)
    def test_returns_defaults_when_no_file(self, _mock_exists):
        result = config.load_config()
        self.assertEqual(result, config.DEFAULTS)
        # Must be a new dict, not a reference to DEFAULTS
        self.assertIsNot(result, config.DEFAULTS)


class TestSaveAndLoadConfig(unittest.TestCase):
    def setUp(self):
        config._cache = None

    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = os.path.join(tmpdir, "settings.json")

            with patch("config.CONFIG_DIR", tmpdir), patch(
                "config.CONFIG_FILE", cfg_file
            ):
                custom = {**config.DEFAULTS, "tmdb_api_key": "my-key-123"}
                config.save_config(custom)
                loaded = config.load_config()

                self.assertEqual(loaded["tmdb_api_key"], "my-key-123")
                self.assertEqual(loaded["auto_eject"], config.DEFAULTS["auto_eject"])


class TestLoadConfigMergesDefaults(unittest.TestCase):
    def setUp(self):
        config._cache = None

    def test_missing_keys_filled(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = os.path.join(tmpdir, "settings.json")

            # Write a partial config
            with open(cfg_file, "w") as f:
                json.dump({"tmdb_api_key": "abc"}, f)

            with patch("config.CONFIG_FILE", cfg_file):
                loaded = config.load_config()

                # Saved key is present
                self.assertEqual(loaded["tmdb_api_key"], "abc")
                # Default keys that were not saved are still present
                self.assertIn("output_dir", loaded)
                self.assertEqual(
                    loaded["min_duration"], config.DEFAULTS["min_duration"]
                )


if __name__ == "__main__":
    unittest.main()
