"""Wrapper around the makemkvcon CLI binary."""

import os
import re
import subprocess
from typing import Callable, Optional

from config import load_config
from core.disc import DiscInfo, TitleInfo


class MakeMKVError(Exception):
    """Base exception for MakeMKV operations."""


class DiscNotFoundError(MakeMKVError):
    """Raised when no disc is detected in the drive."""


class MakeMKVNotFoundError(MakeMKVError):
    """Raised when the makemkvcon binary cannot be found."""


class RipError(MakeMKVError):
    """Raised when a rip operation fails."""


def get_makemkv_path() -> str:
    """Get the path to makemkvcon, verifying it exists."""
    config = load_config()
    path = config.get("makemkv_path", "")
    if not path:
        raise MakeMKVNotFoundError(
            "MakeMKV path is not configured. Set 'makemkv_path' in settings."
        )
    if not os.path.isfile(path):
        raise MakeMKVNotFoundError(f"makemkvcon not found at: {path}")
    if not os.access(path, os.X_OK):
        raise MakeMKVNotFoundError(f"makemkvcon is not executable: {path}")
    return path


def _parse_size_to_bytes(size_str: str) -> int:
    """Parse a human-readable size string (e.g. '4.7 GB') to bytes."""
    size_str = size_str.strip()
    match = re.match(r"([\d.]+)\s*(GB|MB|KB|TB)", size_str, re.IGNORECASE)
    if not match:
        return 0
    value = float(match.group(1))
    unit = match.group(2).upper()
    multipliers = {"KB": 1024, "MB": 1024**2, "GB": 1024**3, "TB": 1024**4}
    return int(value * multipliers[unit])


def scan_disc() -> DiscInfo:
    """Scan the disc in the default drive and return parsed disc info.

    Runs ``makemkvcon -r --cache=1 info disc:0`` and parses the
    structured output into a DiscInfo object.
    """
    mkv_path = get_makemkv_path()
    cmd = [mkv_path, "-r", "--cache=1", "info", "disc:0"]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired as exc:
        raise MakeMKVError("Disc scan timed out after 120 seconds") from exc
    except FileNotFoundError as exc:
        raise MakeMKVNotFoundError(f"Could not execute makemkvcon: {exc}") from exc
    except OSError as exc:
        raise MakeMKVError(f"Failed to run makemkvcon: {exc}") from exc

    output = result.stdout + result.stderr

    if "no disc" in output.lower() or "INSERT DISC" in output:
        raise DiscNotFoundError("No disc found in the drive")

    disc_name = ""
    disc_type = "dvd"
    # title_id -> {attr_code -> value}
    titles_data: dict[int, dict[int, str]] = {}

    for line in output.splitlines():
        # Disc-level info: CINFO:attr_id,attr_code,"value"
        cinfo_match = re.match(r'CINFO:(\d+),\d+,"(.+)"', line)
        if cinfo_match:
            attr_id = int(cinfo_match.group(1))
            value = cinfo_match.group(2)
            if attr_id == 2:
                disc_name = value
            continue

        # Title-level info: TINFO:title_id,attr_id,attr_code,"value"
        tinfo_match = re.match(r'TINFO:(\d+),(\d+),\d+,"(.+)"', line)
        if tinfo_match:
            title_id = int(tinfo_match.group(1))
            attr_id = int(tinfo_match.group(2))
            value = tinfo_match.group(3)
            if title_id not in titles_data:
                titles_data[title_id] = {}
            titles_data[title_id][attr_id] = value
            continue

    # Detect disc type from name or structure heuristics
    if disc_name:
        name_upper = disc_name.upper()
        if "BD" in name_upper or "BLURAY" in name_upper or "BLU-RAY" in name_upper:
            disc_type = "bluray"

    # Check if any title is large enough to suggest Blu-ray (> 15 GB)
    for attrs in titles_data.values():
        size_str = attrs.get(10, "0 MB")
        if _parse_size_to_bytes(size_str) > 15 * (1024**3):
            disc_type = "bluray"
            break

    titles = []
    for tid in sorted(titles_data.keys()):
        attrs = titles_data[tid]
        titles.append(
            TitleInfo(
                id=tid,
                name=attrs.get(2, f"Title {tid}"),
                duration=attrs.get(9, "0:00:00"),
                size_bytes=_parse_size_to_bytes(attrs.get(10, "0 MB")),
                chapters=int(attrs.get(8, "0")),
                file_output=attrs.get(27, ""),
            )
        )

    if not titles and result.returncode != 0:
        raise MakeMKVError(
            f"makemkvcon exited with code {result.returncode} and produced no titles"
        )

    return DiscInfo(name=disc_name, type=disc_type, titles=titles)


def rip_title(
    title_id: int,
    output_dir: str,
    progress_callback: Optional[Callable[[int, str], None]] = None,
) -> str:
    """Rip a single title from disc to the output directory.

    Args:
        title_id: The title index to rip.
        output_dir: Directory where the MKV file will be written.
        progress_callback: Optional ``(percent, message)`` callback for
            progress updates.

    Returns:
        Full path to the ripped MKV file.
    """
    mkv_path = get_makemkv_path()
    os.makedirs(output_dir, exist_ok=True)

    cmd = [mkv_path, "mkv", f"disc:0", str(title_id), output_dir]

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except FileNotFoundError as exc:
        raise MakeMKVNotFoundError(f"Could not execute makemkvcon: {exc}") from exc
    except OSError as exc:
        raise MakeMKVError(f"Failed to start makemkvcon: {exc}") from exc

    output_file = ""

    for line in proc.stdout:  # type: ignore[union-attr]
        line = line.rstrip()

        # Progress: PRGV:current,total,max
        prgv_match = re.match(r"PRGV:(\d+),(\d+),(\d+)", line)
        if prgv_match and progress_callback:
            current = int(prgv_match.group(1))
            pmax = int(prgv_match.group(3))
            percent = int((current / pmax) * 100) if pmax > 0 else 0
            progress_callback(min(percent, 100), f"Ripping: {percent}%")
            continue

        # Progress message: PRGC:code,id,"message"
        prgc_match = re.match(r'PRGC:\d+,\d+,"(.+)"', line)
        if prgc_match and progress_callback:
            progress_callback(-1, prgc_match.group(1))
            continue

        # Capture the output filename from MSG lines
        if "MKV" in line and output_dir in line:
            file_match = re.search(rf"({re.escape(output_dir)}/[^\s\"]+\.mkv)", line)
            if file_match:
                output_file = file_match.group(1)

    proc.wait()

    if proc.returncode != 0:
        raise RipError(
            f"makemkvcon exited with code {proc.returncode} while ripping title {title_id}"
        )

    # If we didn't capture the filename from output, look for it on disk
    if not output_file:
        mkv_files = [f for f in os.listdir(output_dir) if f.endswith(".mkv")]
        if mkv_files:
            mkv_files.sort(key=lambda f: os.path.getmtime(os.path.join(output_dir, f)))
            output_file = os.path.join(output_dir, mkv_files[-1])

    if not output_file or not os.path.isfile(output_file):
        raise RipError(f"Rip completed but output file not found in {output_dir}")

    if progress_callback:
        progress_callback(100, "Rip complete")

    return output_file
