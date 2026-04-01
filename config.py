import json
import os

CONFIG_DIR = os.path.expanduser("~/.config/autoripper")
CONFIG_FILE = os.path.join(CONFIG_DIR, "settings.json")

DEFAULTS = {
    "output_dir": os.path.expanduser("~/Desktop/Ripped"),
    "makemkv_path": "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon",
    "tmdb_api_key": "",
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
