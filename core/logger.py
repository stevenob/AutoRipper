"""Centralized logging for AutoRipper.

Logs to ~/Library/Logs/AutoRipper/autoripper.log with daily rotation
(7-day retention). Also logs to stderr for development use.
"""

from __future__ import annotations

import logging
import os
import sys
from logging.handlers import TimedRotatingFileHandler

APP_NAME = "AutoRipper"
VERSION = "1.0.0"

LOG_DIR = os.path.expanduser("~/Library/Logs/AutoRipper")
LOG_FILE = os.path.join(LOG_DIR, "autoripper.log")

_configured = False


def get_logger(name: str = APP_NAME) -> logging.Logger:
    """Return a named logger, configuring the root logger on first call."""
    global _configured
    if not _configured:
        _configure()
        _configured = True
    return logging.getLogger(name)


def _configure() -> None:
    os.makedirs(LOG_DIR, exist_ok=True)

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # File handler — daily rotation, keep 7 days
    fh = TimedRotatingFileHandler(
        LOG_FILE, when="midnight", backupCount=7, encoding="utf-8",
    )
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)
    root.addHandler(fh)

    # Stderr handler — warnings and above
    sh = logging.StreamHandler(sys.stderr)
    sh.setLevel(logging.WARNING)
    sh.setFormatter(fmt)
    root.addHandler(sh)
