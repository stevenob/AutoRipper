from __future__ import annotations

import json
import os
import tempfile
import threading

CONFIG_DIR = os.path.expanduser("~/.config/autoripper")
CONFIG_FILE = os.path.join(CONFIG_DIR, "settings.json")

DEFAULTS = {
    "output_dir": os.path.expanduser("~/Desktop/Ripped"),
    "makemkv_path": "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon",
    "handbrake_path": "/opt/homebrew/bin/HandBrakeCLI",
    "tmdb_api_key": "",
    "min_duration": 120,
    "auto_eject": True,
    "default_preset": "HQ 1080p30 Surround",
    "default_media_type": "movie",
    "discord_webhook": "",
    "nas_movies_path": "",
    "nas_tv_path": "",
    "nas_upload_enabled": False,
}

_lock = threading.Lock()
_cache: dict | None = None


def load_config() -> dict:
    global _cache
    with _lock:
        if _cache is not None:
            return dict(_cache)
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, "r") as f:
                saved = json.load(f)
            merged = {**DEFAULTS, **saved}
        else:
            merged = dict(DEFAULTS)
        _cache = merged
        return dict(_cache)


def save_config(config: dict):
    global _cache
    with _lock:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=CONFIG_DIR, suffix=".json")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(config, f, indent=2)
            os.replace(tmp, CONFIG_FILE)
        except BaseException:
            os.unlink(tmp)
            raise
        _cache = dict(config)
