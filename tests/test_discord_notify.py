from __future__ import annotations

import os
import sys
import unittest
from unittest.mock import MagicMock, patch, call

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import core.discord_notify as dn


class TestBuildEmbed(unittest.TestCase):
    def test_title_contains_disc_name(self):
        stages = {"rip": "done", "encode": "active", "organize": "pending",
                  "scrape": "pending", "nas": "skipped"}
        embed = dn._build_embed("MY_MOVIE", stages, {})
        self.assertIn("MY_MOVIE", embed["title"])

    def test_description_lines_have_icons(self):
        stages = {"rip": "done", "encode": "active", "organize": "pending",
                  "scrape": "failed", "nas": "skipped"}
        embed = dn._build_embed("D", stages, {})
        desc = embed["description"]
        self.assertIn(dn._ICON_DONE, desc)
        self.assertIn(dn._ICON_ACTIVE, desc)
        self.assertIn(dn._ICON_PENDING, desc)
        self.assertIn(dn._ICON_FAIL, desc)
        self.assertIn(dn._ICON_SKIP, desc)

    def test_stage_details_included(self):
        stages = {"rip": "done", "encode": "pending", "organize": "pending",
                  "scrape": "pending", "nas": "pending"}
        details = {"rip": "4.2 GB · 5m30s"}
        embed = dn._build_embed("D", stages, details)
        self.assertIn("4.2 GB · 5m30s", embed["description"])

    def test_footer_when_provided(self):
        stages = {k: "pending" for k in ("rip", "encode", "organize", "scrape", "nas")}
        embed = dn._build_embed("D", stages, {}, footer="Total: 10m")
        self.assertEqual(embed["footer"]["text"], "Total: 10m")

    def test_no_footer_when_empty(self):
        stages = {k: "pending" for k in ("rip", "encode", "organize", "scrape", "nas")}
        embed = dn._build_embed("D", stages, {})
        self.assertNotIn("footer", embed)

    def test_color_passed_through(self):
        stages = {k: "pending" for k in ("rip", "encode", "organize", "scrape", "nas")}
        embed = dn._build_embed("D", stages, {}, color=0xFF0000)
        self.assertEqual(embed["color"], 0xFF0000)

    def test_all_stages_present_in_description(self):
        stages = {k: "pending" for k in ("rip", "encode", "organize", "scrape", "nas")}
        embed = dn._build_embed("D", stages, {})
        for label in dn._STAGE_LABELS.values():
            self.assertIn(label, embed["description"])


class TestSendEmbed(unittest.TestCase):
    @patch("core.discord_notify._session.post")
    @patch("core.discord_notify._get_webhook_url", return_value="https://discord.com/api/webhooks/123/abc")
    def test_posts_to_webhook_with_wait(self, mock_url, mock_post):
        mock_resp = MagicMock()
        mock_resp.ok = True
        mock_resp.json.return_value = {"id": "msg_42"}
        mock_post.return_value = mock_resp

        result = dn.send_embed({"title": "test"})
        mock_post.assert_called_once()
        url_arg = mock_post.call_args[0][0]
        self.assertIn("?wait=true", url_arg)
        self.assertEqual(result, "msg_42")

    @patch("core.discord_notify._get_webhook_url", return_value="")
    def test_returns_none_when_no_webhook(self, mock_url):
        result = dn.send_embed({"title": "test"})
        self.assertIsNone(result)

    @patch("core.discord_notify._session.post", side_effect=Exception("network"))
    @patch("core.discord_notify._get_webhook_url", return_value="https://hook.url")
    def test_returns_none_on_exception(self, mock_url, mock_post):
        result = dn.send_embed({"title": "test"})
        self.assertIsNone(result)

    @patch("core.discord_notify._session.post")
    @patch("core.discord_notify._get_webhook_url", return_value="https://hook.url")
    def test_returns_none_when_response_not_ok(self, mock_url, mock_post):
        mock_resp = MagicMock()
        mock_resp.ok = False
        mock_post.return_value = mock_resp
        result = dn.send_embed({"title": "test"})
        self.assertIsNone(result)


class TestEditEmbed(unittest.TestCase):
    @patch("core.discord_notify._session.patch")
    @patch("core.discord_notify._get_webhook_url", return_value="https://discord.com/api/webhooks/123/abc")
    def test_patches_correct_url(self, mock_url, mock_patch):
        dn.edit_embed("msg_42", {"title": "updated"})
        url_arg = mock_patch.call_args[0][0]
        self.assertIn("/messages/msg_42", url_arg)

    @patch("core.discord_notify._session.patch")
    @patch("core.discord_notify._get_webhook_url", return_value="")
    def test_no_patch_when_no_webhook(self, mock_url, mock_patch):
        dn.edit_embed("msg_42", {"title": "x"})
        mock_patch.assert_not_called()

    @patch("core.discord_notify._session.patch")
    @patch("core.discord_notify._get_webhook_url", return_value="https://hook.url")
    def test_no_patch_when_no_message_id(self, mock_url, mock_patch):
        dn.edit_embed("", {"title": "x"})
        mock_patch.assert_not_called()

    @patch("core.discord_notify._session.patch", side_effect=Exception("err"))
    @patch("core.discord_notify._get_webhook_url", return_value="https://hook.url")
    def test_does_not_raise_on_exception(self, mock_url, mock_patch):
        dn.edit_embed("msg_42", {"title": "x"})


class TestJobCard(unittest.TestCase):
    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_init_default_stages(self, mock_send):
        card = dn.JobCard("MOVIE")
        self.assertEqual(card._stages["rip"], "pending")
        self.assertEqual(card._stages["nas"], "skipped")

    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_init_nas_enabled(self, mock_send):
        card = dn.JobCard("MOVIE", nas_enabled=True)
        self.assertEqual(card._stages["nas"], "pending")

    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_start_sets_active(self, mock_send):
        card = dn.JobCard("MOVIE")
        card.start("rip")
        self.assertEqual(card._stages["rip"], "active")
        mock_send.assert_called_once()

    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_finish_sets_done(self, mock_send):
        card = dn.JobCard("MOVIE")
        card.finish("encode", detail="100MB")
        self.assertEqual(card._stages["encode"], "done")
        self.assertEqual(card._stage_details["encode"], "100MB")

    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_fail_sets_failed(self, mock_send):
        card = dn.JobCard("MOVIE")
        card.fail("encode", detail="OOM")
        self.assertEqual(card._stages["encode"], "failed")

    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_fail_uses_error_color(self, mock_send):
        card = dn.JobCard("MOVIE")
        card.fail("encode")
        embed_arg = mock_send.call_args[0][0]
        self.assertEqual(embed_arg["color"], dn._COLOR_ERROR)

    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_skip_sets_skipped(self, mock_send):
        card = dn.JobCard("MOVIE")
        card.skip("nas")
        self.assertEqual(card._stages["nas"], "skipped")

    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_complete_uses_success_color(self, mock_send):
        card = dn.JobCard("MOVIE")
        card.complete(footer="done!")
        embed_arg = mock_send.call_args[0][0]
        self.assertEqual(embed_arg["color"], dn._COLOR_SUCCESS)

    @patch("core.discord_notify.edit_embed")
    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_second_call_uses_edit(self, mock_send, mock_edit):
        card = dn.JobCard("MOVIE")
        card.start("rip")  # first call -> send_embed
        card.finish("rip")  # second call -> edit_embed
        mock_send.assert_called_once()
        mock_edit.assert_called_once()
        self.assertEqual(mock_edit.call_args[0][0], "msg_1")

    @patch("core.discord_notify.send_embed", return_value="msg_1")
    def test_start_with_detail(self, mock_send):
        card = dn.JobCard("MOVIE")
        card.start("rip", detail="Reading disc…")
        self.assertEqual(card._stage_details["rip"], "Reading disc…")


class TestStandaloneHelpers(unittest.TestCase):
    @patch("core.discord_notify.send_embed")
    def test_send_notification(self, mock_send):
        dn.send_notification("hello", title="Bot", color=0x123)
        embed = mock_send.call_args[0][0]
        self.assertEqual(embed["title"], "Bot")
        self.assertEqual(embed["description"], "hello")
        self.assertEqual(embed["color"], 0x123)

    @patch("core.discord_notify.send_embed")
    def test_notify_info_uses_blue(self, mock_send):
        dn.notify_info("msg")
        embed = mock_send.call_args[0][0]
        self.assertEqual(embed["color"], 0x5865F2)

    @patch("core.discord_notify.send_embed")
    def test_notify_progress_uses_yellow(self, mock_send):
        dn.notify_progress("msg")
        embed = mock_send.call_args[0][0]
        self.assertEqual(embed["color"], 0xFEE75C)

    @patch("core.discord_notify.send_embed")
    def test_notify_success_uses_green(self, mock_send):
        dn.notify_success("msg")
        embed = mock_send.call_args[0][0]
        self.assertEqual(embed["color"], 0x57F287)

    @patch("core.discord_notify.send_embed")
    def test_notify_error_uses_red(self, mock_send):
        dn.notify_error("msg")
        embed = mock_send.call_args[0][0]
        self.assertEqual(embed["color"], 0xED4245)


if __name__ == "__main__":
    unittest.main()
