from __future__ import annotations

import logging
import os
import sys
import unittest
from unittest.mock import MagicMock, patch, call

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import core.logger as logger_mod


class TestGetLogger(unittest.TestCase):
    def setUp(self):
        logger_mod._configured = False
        # Remove any handlers added by previous tests
        root = logging.getLogger()
        self._original_handlers = root.handlers[:]

    def tearDown(self):
        logger_mod._configured = False
        root = logging.getLogger()
        # Remove handlers added during the test
        for h in root.handlers[:]:
            if h not in self._original_handlers:
                root.removeHandler(h)
                h.close()

    @patch("core.logger._configure")
    def test_returns_logger_instance(self, mock_configure):
        result = logger_mod.get_logger()
        self.assertIsInstance(result, logging.Logger)

    @patch("core.logger._configure")
    def test_default_name_is_app_name(self, mock_configure):
        result = logger_mod.get_logger()
        self.assertEqual(result.name, logger_mod.APP_NAME)

    @patch("core.logger._configure")
    def test_custom_name(self, mock_configure):
        result = logger_mod.get_logger("my.module")
        self.assertEqual(result.name, "my.module")

    @patch("core.logger._configure")
    def test_calls_configure_on_first_call(self, mock_configure):
        logger_mod.get_logger()
        mock_configure.assert_called_once()

    @patch("core.logger._configure")
    def test_configure_only_called_once(self, mock_configure):
        logger_mod.get_logger()
        logger_mod.get_logger("second")
        logger_mod.get_logger("third")
        mock_configure.assert_called_once()

    @patch("core.logger._configure")
    def test_configured_flag_set_after_first_call(self, mock_configure):
        self.assertFalse(logger_mod._configured)
        logger_mod.get_logger()
        self.assertTrue(logger_mod._configured)


class TestConfigure(unittest.TestCase):
    def setUp(self):
        logger_mod._configured = False
        root = logging.getLogger()
        self._original_handlers = root.handlers[:]

    def tearDown(self):
        logger_mod._configured = False
        root = logging.getLogger()
        for h in root.handlers[:]:
            if h not in self._original_handlers:
                root.removeHandler(h)
                h.close()

    @patch("core.logger.TimedRotatingFileHandler")
    @patch("core.logger.os.makedirs")
    def test_creates_log_dir(self, mock_makedirs, mock_handler_cls):
        mock_handler_cls.return_value = MagicMock(spec=logging.Handler)
        logger_mod._configure()
        mock_makedirs.assert_called_once_with(logger_mod.LOG_DIR, exist_ok=True)

    @patch("core.logger.TimedRotatingFileHandler")
    @patch("core.logger.os.makedirs")
    def test_adds_file_handler(self, mock_makedirs, mock_handler_cls):
        mock_fh = MagicMock(spec=logging.Handler)
        mock_handler_cls.return_value = mock_fh
        logger_mod._configure()
        mock_handler_cls.assert_called_once_with(
            logger_mod.LOG_FILE, when="midnight", backupCount=7, encoding="utf-8",
        )
        mock_fh.setLevel.assert_called_once_with(logging.DEBUG)
        mock_fh.setFormatter.assert_called_once()

    @patch("core.logger.TimedRotatingFileHandler")
    @patch("core.logger.os.makedirs")
    def test_adds_stderr_handler(self, mock_makedirs, mock_handler_cls):
        mock_handler_cls.return_value = MagicMock(spec=logging.Handler)
        logger_mod._configure()
        root = logging.getLogger()
        # Find the StreamHandler that was added (not the mock file handler)
        stream_handlers = [
            h for h in root.handlers
            if isinstance(h, logging.StreamHandler)
            and not isinstance(h, logging.FileHandler)
            and h not in self._original_handlers
        ]
        self.assertTrue(len(stream_handlers) >= 1)
        sh = stream_handlers[0]
        self.assertEqual(sh.level, logging.WARNING)

    @patch("core.logger.TimedRotatingFileHandler")
    @patch("core.logger.os.makedirs")
    def test_sets_root_level_to_debug(self, mock_makedirs, mock_handler_cls):
        mock_handler_cls.return_value = MagicMock(spec=logging.Handler)
        logger_mod._configure()
        root = logging.getLogger()
        self.assertEqual(root.level, logging.DEBUG)


class TestModuleConstants(unittest.TestCase):
    def test_app_name(self):
        self.assertEqual(logger_mod.APP_NAME, "AutoRipper")

    def test_version(self):
        self.assertEqual(logger_mod.VERSION, "1.0.0")

    def test_log_dir_path(self):
        self.assertIn("AutoRipper", logger_mod.LOG_DIR)

    def test_log_file_path(self):
        self.assertTrue(logger_mod.LOG_FILE.endswith("autoripper.log"))


if __name__ == "__main__":
    unittest.main()
