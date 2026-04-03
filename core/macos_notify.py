"""macOS Notification Center alerts via osascript.

Fires native banners for key pipeline events. Fails silently —
notifications are best-effort, like Discord webhooks.
"""

from __future__ import annotations

import subprocess


def notify(title: str, message: str, sound: str = "default") -> None:
    """Post a macOS Notification Center banner."""
    script = (
        f'display notification "{_escape(message)}" '
        f'with title "{_escape(title)}" '
        f'sound name "{sound}"'
    )
    try:
        subprocess.Popen(
            ["osascript", "-e", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def _escape(text: str) -> str:
    """Escape double quotes and backslashes for AppleScript strings."""
    return text.replace("\\", "\\\\").replace('"', '\\"')
