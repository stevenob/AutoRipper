from __future__ import annotations

import json
import os

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
}


def load_config() -> dict:
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "r") as f:
            saved = json.load(f)
        merged = {**DEFAULTS, **saved}
        return merged
    return dict(DEFAULTS)


def save_config(config: dict):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)
