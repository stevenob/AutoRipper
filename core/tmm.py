"""Wrapper around the tinyMediaManager (tMM) CLI."""

from __future__ import annotations

import os
import subprocess
from typing import Callable, Optional

from config import load_config

_DEFAULT_TMM_DIR = "/Applications/tinyMediaManager.app/Contents/Resources/Java"


class TmmError(Exception):
    """Base exception for tinyMediaManager operations."""


class TmmNotFoundError(TmmError):
    """Raised when tMM installation cannot be found."""


def get_tmm_dir() -> str:
    """Get the tMM installation directory, verifying ``tmm.jar`` exists."""
    config = load_config()
    tmm_dir = config.get("tmm_path", _DEFAULT_TMM_DIR)
    if not tmm_dir:
        raise TmmNotFoundError(
            "tMM path is not configured. Set 'tmm_path' in settings."
        )
    jar = os.path.join(tmm_dir, "tmm.jar")
    if not os.path.isfile(jar):
        raise TmmNotFoundError(f"tmm.jar not found at: {jar}")
    return tmm_dir


def _build_tmm_cmd(args: list[str]) -> list[str]:
    """Build the full Java command to invoke tMM.

    Args:
        args: CLI arguments to pass after the main class
              (e.g. ``["movie", "-u", "-n", "-r"]``).

    Returns:
        Complete command list suitable for :class:`subprocess.Popen`.
    """
    tmm_dir = get_tmm_dir()
    java = os.path.join(tmm_dir, "jre", "bin", "java")
    classpath = os.path.join(tmm_dir, "tmm.jar") + ":" + os.path.join(tmm_dir, "lib", "*")

    return [
        java,
        "--add-opens=java.base/sun.net.www.protocol.http=ALL-UNNAMED",
        "-Xms64m",
        "-Xmx512m",
        "-Dfile.encoding=UTF-8",
        "-cp", classpath,
        "org.tinymediamanager.TinyMediaManager",
        *args,
    ]


def run_tmm(
    media_type: str,
    options: list[str],
    log_callback: Optional[Callable[[str], None]] = None,
    proc_callback: Optional[Callable] = None,
) -> bool:
    """Run a tMM CLI command.

    Args:
        media_type: ``"movie"`` or ``"tvshow"``.
        options: CLI flags (e.g. ``["-u", "-n", "-r"]``).
        log_callback: Optional callback receiving each output line.
        proc_callback: Optional callback receiving the :class:`~subprocess.Popen`
            object (for abort support).

    Returns:
        ``True`` on success, ``False`` on failure.
    """
    cmd = _build_tmm_cmd([media_type] + options)

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError as exc:
        raise TmmNotFoundError(f"Could not execute tMM Java runtime: {exc}") from exc
    except OSError as exc:
        raise TmmError(f"Failed to start tMM: {exc}") from exc

    if proc_callback:
        proc_callback(proc)

    for line in iter(proc.stdout.readline, ""):  # type: ignore[union-attr]
        line = line.rstrip()
        if not line:
            continue
        if log_callback:
            log_callback(line)

    proc.wait()
    return proc.returncode == 0


def scrape_and_rename(
    media_type: str,
    log_callback: Optional[Callable[[str], None]] = None,
    proc_callback: Optional[Callable] = None,
) -> bool:
    """Update data sources, scrape new items, and rename.

    Convenience wrapper around :func:`run_tmm` with ``-u -n -r`` flags.
    """
    return run_tmm(media_type, ["-u", "-n", "-r"], log_callback, proc_callback)


def download_subtitles(
    media_type: str,
    log_callback: Optional[Callable[[str], None]] = None,
    proc_callback: Optional[Callable] = None,
) -> bool:
    """Download subtitles for the given media type.

    Convenience wrapper around :func:`run_tmm` with ``-s`` flag.
    """
    return run_tmm(media_type, ["-s"], log_callback, proc_callback)
