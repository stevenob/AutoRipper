from __future__ import annotations

import requests
from typing import Optional

from config import load_config


def send_notification(message: str, title: str = "AutoRipper", color: int = 0x5865F2):
    """Send a Discord embed notification via webhook.

    Does nothing if webhook URL is not configured. Never raises —
    notifications are fire-and-forget.

    Args:
        message: The notification body text
        title: Embed title (default "AutoRipper")
        color: Embed color as int (Discord blue default)
    """
    config = load_config()
    webhook_url = config.get("discord_webhook", "")
    if not webhook_url:
        return

    payload = {
        "embeds": [{
            "title": title,
            "description": message,
            "color": color,
        }]
    }

    try:
        requests.post(webhook_url, json=payload, timeout=5)
    except Exception:
        pass  # notifications are best-effort


# Convenience functions with appropriate colors
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
