from __future__ import annotations

import os
import subprocess
import sys
import unittest
from unittest.mock import MagicMock, patch, call

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.macos_notify import notify, _escape


class TestEscape(unittest.TestCase):
    def test_escapes_double_quotes(self):
        self.assertEqual(_escape('say "hello"'), 'say \\"hello\\"')

    def test_escapes_backslashes(self):
        self.assertEqual(_escape("back\\slash"), "back\\\\slash")

    def test_escapes_both(self):
        self.assertEqual(_escape('a\\b"c'), 'a\\\\b\\"c')

    def test_no_special_chars(self):
        self.assertEqual(_escape("plain text"), "plain text")

    def test_empty_string(self):
        self.assertEqual(_escape(""), "")


class TestNotify(unittest.TestCase):
    @patch("core.macos_notify.subprocess.Popen")
    def test_calls_osascript(self, mock_popen):
        notify("Title", "Message")
        mock_popen.assert_called_once()
        args = mock_popen.call_args
        cmd = args[0][0]
        self.assertEqual(cmd[0], "osascript")
        self.assertEqual(cmd[1], "-e")

    @patch("core.macos_notify.subprocess.Popen")
    def test_script_contains_title_and_message(self, mock_popen):
        notify("My Title", "My Message")
        cmd = mock_popen.call_args[0][0]
        script = cmd[2]
        self.assertIn("My Title", script)
        self.assertIn("My Message", script)

    @patch("core.macos_notify.subprocess.Popen")
    def test_script_contains_default_sound(self, mock_popen):
        notify("T", "M")
        script = mock_popen.call_args[0][0][2]
        self.assertIn('sound name "default"', script)

    @patch("core.macos_notify.subprocess.Popen")
    def test_custom_sound(self, mock_popen):
        notify("T", "M", sound="Ping")
        script = mock_popen.call_args[0][0][2]
        self.assertIn('sound name "Ping"', script)

    @patch("core.macos_notify.subprocess.Popen")
    def test_escapes_special_chars_in_message(self, mock_popen):
        notify("Title", 'He said "hi"')
        script = mock_popen.call_args[0][0][2]
        self.assertIn('\\"hi\\"', script)

    @patch("core.macos_notify.subprocess.Popen")
    def test_devnull_for_stdout_stderr(self, mock_popen):
        notify("T", "M")
        kwargs = mock_popen.call_args[1]
        self.assertEqual(kwargs["stdout"], subprocess.DEVNULL)
        self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)

    @patch("core.macos_notify.subprocess.Popen", side_effect=FileNotFoundError("no osascript"))
    def test_does_not_raise_on_popen_failure(self, mock_popen):
        # Should silently swallow the exception
        notify("T", "M")

    @patch("core.macos_notify.subprocess.Popen", side_effect=OSError("broken"))
    def test_does_not_raise_on_os_error(self, mock_popen):
        notify("T", "M")


if __name__ == "__main__":
    unittest.main()
