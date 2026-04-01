from __future__ import annotations

import os
import sys
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


class TestAutoSelectPreset(unittest.TestCase):
    """Test that _auto_select_preset picks the right H.265 preset for each resolution."""

    def _make_tab(self):
        """Create an EncodeTab with mocked tkinter."""
        import tkinter as tk

        root = tk.Tk()
        root.withdraw()

        # Mock the app
        mock_app = MagicMock()
        mock_app.set_status = MagicMock()

        from gui.encode_tab import EncodeTab

        tab = EncodeTab(root, app=mock_app)
        return tab, root

    def test_dvd_480p_selects_h265_480p(self):
        tab, root = self._make_tab()
        try:
            tab._auto_select_preset("720x480")
            self.assertEqual(tab.preset_var.get(), "H.265 MKV 480p30")
        finally:
            root.destroy()

    def test_bluray_1080p_selects_videotoolbox(self):
        tab, root = self._make_tab()
        try:
            tab._auto_select_preset("1920x1080")
            self.assertEqual(tab.preset_var.get(), "H.265 Apple VideoToolbox 1080p")
        finally:
            root.destroy()

    def test_4k_uhd_selects_videotoolbox_4k(self):
        tab, root = self._make_tab()
        try:
            tab._auto_select_preset("3840x2160")
            self.assertEqual(tab.preset_var.get(), "H.265 Apple VideoToolbox 2160p 4K")
        finally:
            root.destroy()

    def test_720p_selects_h265_720p(self):
        tab, root = self._make_tab()
        try:
            tab._auto_select_preset("1280x720")
            self.assertEqual(tab.preset_var.get(), "H.265 MKV 720p30")
        finally:
            root.destroy()

    def test_576p_selects_h265_576p(self):
        tab, root = self._make_tab()
        try:
            tab._auto_select_preset("720x576")
            self.assertEqual(tab.preset_var.get(), "H.265 MKV 576p25")
        finally:
            root.destroy()

    def test_empty_resolution_no_change(self):
        tab, root = self._make_tab()
        try:
            original = tab.preset_var.get()
            tab._auto_select_preset("")
            self.assertEqual(tab.preset_var.get(), original)
        finally:
            root.destroy()


if __name__ == "__main__":
    unittest.main()
