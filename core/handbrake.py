"""Wrapper around the HandBrakeCLI binary."""

from __future__ import annotations

import os
import re
import subprocess
from typing import Callable, Optional

from config import load_config


class HandBrakeError(Exception):
    """Base exception for HandBrake operations."""


class HandBrakeNotFoundError(HandBrakeError):
    """Raised when the HandBrakeCLI binary cannot be found."""


_cached_presets: list[str] | None = None


def get_handbrake_path() -> str:
    """Get the path to HandBrakeCLI, verifying it exists."""
    config = load_config()
    path = config.get("handbrake_path", "/opt/homebrew/bin/HandBrakeCLI")
    if not path:
        raise HandBrakeNotFoundError(
            "HandBrake path is not configured. Set 'handbrake_path' in settings."
        )
    if not os.path.isfile(path):
        raise HandBrakeNotFoundError(f"HandBrakeCLI not found at: {path}")
    if not os.access(path, os.X_OK):
        raise HandBrakeNotFoundError(f"HandBrakeCLI is not executable: {path}")
    return path


def list_presets() -> list[str]:
    """Return a flat list of HandBrake preset names.

    Results are cached after the first successful call.
    """
    global _cached_presets
    if _cached_presets is not None:
        return list(_cached_presets)

    hb_path = get_handbrake_path()
    try:
        result = subprocess.run(
            [hb_path, "--preset-list"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except FileNotFoundError as exc:
        raise HandBrakeNotFoundError(f"Could not execute HandBrakeCLI: {exc}") from exc
    except OSError as exc:
        raise HandBrakeError(f"Failed to run HandBrakeCLI: {exc}") from exc

    output = result.stdout + result.stderr
    presets: list[str] = []
    for line in output.splitlines():
        # Preset lines look like "    + Preset Name" (indented with +)
        m = re.match(r"^\s{4,}\+\s+(.+)$", line)
        if m:
            name = m.group(1).strip()
            # Skip category headers (they appear as less-indented lines with a colon)
            if name and not name.endswith("/"):
                presets.append(name)

    _cached_presets = presets
    return list(presets)


def scan_tracks(input_path: str) -> dict:
    """Scan an input file and return audio and subtitle track info.

    Returns:
        Dictionary with ``"audio"`` and ``"subtitles"`` lists.
    """
    hb_path = get_handbrake_path()
    try:
        result = subprocess.run(
            [hb_path, "--scan", "--input", input_path],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except FileNotFoundError as exc:
        raise HandBrakeNotFoundError(f"Could not execute HandBrakeCLI: {exc}") from exc
    except OSError as exc:
        raise HandBrakeError(f"Failed to run HandBrakeCLI: {exc}") from exc

    output = result.stderr + result.stdout
    audio_tracks: list[dict] = []
    subtitle_tracks: list[dict] = []

    section = None
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("+ audio tracks:"):
            section = "audio"
            continue
        elif stripped.startswith("+ subtitle tracks:"):
            section = "subtitles"
            continue
        elif stripped.startswith("+ ") and not stripped.startswith("+ ") or (
            re.match(r"^\s*\+\s+\w", line) and not re.match(r"^\s{4,}\+\s+\d+,", line)
        ):
            # A new top-level section that isn't a track line
            if section and not re.match(r"^\s{4,}\+\s+\d+,", line):
                section = None

        if section == "audio":
            # Match: + 1, English (AC3) (5.1 ch) (iso639-2: eng)
            m = re.match(r"^\s+\+\s+(\d+),\s+(.+)$", line)
            if m:
                index = int(m.group(1))
                description = m.group(2).strip()

                lang_m = re.match(r"^(\w[\w\s]*?)(?:\s*\()", description)
                language = lang_m.group(1).strip() if lang_m else "Unknown"

                codec_m = re.search(r"\((\w+)\)", description)
                codec = codec_m.group(1) if codec_m else "Unknown"

                audio_tracks.append({
                    "index": index,
                    "language": language,
                    "codec": codec,
                    "description": f"{language} ({codec})" + (
                        f" {ch.group(0)}" if (ch := re.search(r"\([\d.]+\s*ch\)", description)) else ""
                    ),
                })

        elif section == "subtitles":
            # Match: + 1, English (PGS) (iso639-2: eng)
            m = re.match(r"^\s+\+\s+(\d+),\s+(.+)$", line)
            if m:
                index = int(m.group(1))
                description = m.group(2).strip()

                lang_m = re.match(r"^(\w[\w\s]*?)(?:\s*\()", description)
                language = lang_m.group(1).strip() if lang_m else "Unknown"

                type_m = re.search(r"\((\w+)\)", description)
                sub_type = type_m.group(1) if type_m else "Unknown"

                subtitle_tracks.append({
                    "index": index,
                    "language": language,
                    "type": sub_type,
                })

    return {"audio": audio_tracks, "subtitles": subtitle_tracks}


def encode(
    input_path: str,
    output_path: str,
    preset: str,
    audio_tracks: Optional[list[int]] = None,
    subtitle_tracks: Optional[list[int]] = None,
    progress_callback: Optional[Callable[[int, str], None]] = None,
    proc_callback: Optional[Callable] = None,
) -> str:
    """Encode a video file using HandBrakeCLI.

    Args:
        input_path: Path to the source MKV file.
        output_path: Path for the encoded output file.
        preset: HandBrake preset name to use.
        audio_tracks: Optional list of audio track indices to include.
        subtitle_tracks: Optional list of subtitle track indices to include.
        progress_callback: Optional ``(percent, message)`` callback.
        proc_callback: Optional callback receiving the Popen object
            (for abort support).

    Returns:
        Path to the encoded output file.
    """
    hb_path = get_handbrake_path()

    # Ensure output has .mkv extension
    base, _ = os.path.splitext(output_path)
    output_path = base + ".mkv"

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)

    cmd = [hb_path, "-i", input_path, "-o", output_path, "--preset", preset]

    if audio_tracks:
        cmd.extend(["--audio", ",".join(str(t) for t in audio_tracks)])
    if subtitle_tracks:
        cmd.extend(["--subtitle", ",".join(str(t) for t in subtitle_tracks)])

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError as exc:
        raise HandBrakeNotFoundError(f"Could not execute HandBrakeCLI: {exc}") from exc
    except OSError as exc:
        raise HandBrakeError(f"Failed to start HandBrakeCLI: {exc}") from exc

    if proc_callback:
        proc_callback(proc)

    # Read stderr for progress (HandBrake writes progress to stderr)
    for line in proc.stderr:  # type: ignore[union-attr]
        line = line.rstrip()
        # Progress line: Encoding: task 1 of 1, 45.23 % (30.15 fps, avg 28.44 fps, ETA 00h12m30s)
        m = re.search(r"(\d+\.\d+)\s*%", line)
        if m and progress_callback:
            percent = int(float(m.group(1)))
            # Extract ETA if present
            eta_m = re.search(r"ETA\s+(\S+)", line)
            eta = f", ETA {eta_m.group(1)}" if eta_m else ""
            progress_callback(min(percent, 100), f"Encoding: {percent}%{eta}")

    proc.wait()

    if proc.returncode != 0:
        raise HandBrakeError(
            f"HandBrakeCLI exited with code {proc.returncode}"
        )

    if not os.path.isfile(output_path):
        raise HandBrakeError(f"Encoding completed but output file not found: {output_path}")

    if progress_callback:
        progress_callback(100, "Encoding complete")

    return output_path
