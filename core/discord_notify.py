from __future__ import annotations

import requests
from typing import Optional

from config import load_config

# Reusable session for connection pooling across webhook calls
_session = requests.Session()

# Stage display order and labels
_STAGES = ("rip", "encode", "organize", "scrape", "nas")
_STAGE_LABELS = {
    "rip": "Rip",
    "encode": "Encode",
    "organize": "Organize",
    "scrape": "Artwork & NFO",
    "nas": "Copy to NAS",
}
_ICON_PENDING = "⬜"
_ICON_ACTIVE = "🔄"
_ICON_DONE = "✅"
_ICON_FAIL = "❌"
_ICON_SKIP = "⏭️"

_COLOR_ACTIVE = 0x5865F2   # blue
_COLOR_SUCCESS = 0x57F287  # green
_COLOR_ERROR = 0xED4245    # red


def _get_webhook_url() -> str:
    return load_config().get("discord_webhook", "")


# ------------------------------------------------------------------ low-level

def send_embed(embed: dict) -> str | None:
    """Post an embed and return the message ID (or None)."""
    url = _get_webhook_url()
    if not url:
        return None
    try:
        resp = _session.post(
            f"{url}?wait=true", json={"embeds": [embed]}, timeout=10,
        )
        if resp.ok:
            return resp.json().get("id")
    except Exception:
        pass
    return None


def edit_embed(message_id: str, embed: dict) -> None:
    """Edit an existing webhook message in place."""
    url = _get_webhook_url()
    if not url or not message_id:
        return
    try:
        _session.patch(
            f"{url}/messages/{message_id}", json={"embeds": [embed]}, timeout=10,
        )
    except Exception:
        pass


# --------------------------------------------------------- job-card builder

def _build_embed(
    disc_name: str,
    stages: dict[str, str],
    stage_details: dict[str, str],
    footer: str = "",
    color: int = _COLOR_ACTIVE,
) -> dict:
    """Build an embed dict for a job.

    ``stages`` maps stage key -> status ("pending" | "active" | "done"
    | "failed" | "skipped"), controlling the icon shown per line.
    ``stage_details`` maps stage key -> inline stats string.
    """
    icon_map = {
        "pending": _ICON_PENDING,
        "active": _ICON_ACTIVE,
        "done": _ICON_DONE,
        "failed": _ICON_FAIL,
        "skipped": _ICON_SKIP,
    }
    lines = []
    for key in _STAGES:
        status = stages.get(key, "pending")
        icon = icon_map.get(status, _ICON_PENDING)
        line = f"{icon}  {_STAGE_LABELS[key]}"
        info = stage_details.get(key, "")
        if info:
            line += f"  —  {info}"
        lines.append(line)

    embed: dict = {
        "title": f"🎬  {disc_name}",
        "description": "\n".join(lines),
        "color": color,
    }
    if footer:
        embed["footer"] = {"text": footer}
    return embed


class JobCard:
    """Manages a single Discord embed that is updated in place per job."""

    def __init__(self, disc_name: str, *, nas_enabled: bool = False) -> None:
        self.disc_name = disc_name
        self.nas_enabled = nas_enabled
        self._message_id: str | None = None
        self._stages: dict[str, str] = {
            "rip": "pending",
            "encode": "pending",
            "organize": "pending",
            "scrape": "pending",
            "nas": "skipped" if not nas_enabled else "pending",
        }
        self._stage_details: dict[str, str] = {}

    def _send_or_edit(self, color: int = _COLOR_ACTIVE, footer: str = "") -> None:
        embed = _build_embed(
            self.disc_name, self._stages, self._stage_details,
            footer=footer, color=color,
        )
        if self._message_id is None:
            self._message_id = send_embed(embed)
        else:
            edit_embed(self._message_id, embed)

    def start(self, stage: str, detail: str = "") -> None:
        self._stages[stage] = "active"
        if detail:
            self._stage_details[stage] = detail
        self._send_or_edit()

    def finish(self, stage: str, detail: str = "") -> None:
        self._stages[stage] = "done"
        if detail:
            self._stage_details[stage] = detail
        self._send_or_edit()

    def fail(self, stage: str, detail: str = "") -> None:
        self._stages[stage] = "failed"
        if detail:
            self._stage_details[stage] = detail
        self._send_or_edit(color=_COLOR_ERROR)

    def skip(self, stage: str) -> None:
        self._stages[stage] = "skipped"
        self._send_or_edit()

    def complete(self, footer: str = "") -> None:
        self._send_or_edit(color=_COLOR_SUCCESS, footer=footer)


# ------------------------------------------------ standalone one-shot helpers

def send_notification(message: str, title: str = "AutoRipper", color: int = 0x5865F2):
    """Send a one-shot Discord embed (for events outside the job queue)."""
    embed = {"title": title, "description": message, "color": color}
    send_embed(embed)


def notify_info(message: str):
    """Blue notification for general info."""
    send_notification(message, color=0x5865F2)


def notify_progress(message: str):
    """Yellow notification for progress updates."""
    send_notification(message, title="⏳ In Progress", color=0xFEE75C)


def notify_success(message: str):
    """Green notification for success."""
    send_notification(message, title="✅ Complete", color=0x57F287)


def notify_error(message: str):
    """Red notification for errors."""
    send_notification(message, title="❌ Error", color=0xED4245)
