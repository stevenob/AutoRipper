"""Download artwork and create NFO files using TMDb API."""

from __future__ import annotations

import os
import xml.etree.ElementTree as ET
from typing import Optional, Callable

import requests

from config import load_config
from core.metadata import search_media, get_movie_details, get_tv_details, MediaResult

TMDB_IMAGE_BASE = "https://image.tmdb.org/t/p"


def _fetch_backdrop_path(tmdb_id: int, media_type: str) -> Optional[str]:
    """Fetch backdrop_path from TMDb API for a movie or TV show."""
    config = load_config()
    api_key = config.get("tmdb_api_key", "")
    if not api_key:
        return None
    endpoint = "movie" if media_type == "movie" else "tv"
    try:
        resp = requests.get(
            f"https://api.themoviedb.org/3/{endpoint}/{tmdb_id}",
            params={"api_key": api_key},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json().get("backdrop_path")
    except Exception:
        return None


def _download_image(url: str, dest: str, log_callback: Optional[Callable[[str], None]] = None) -> bool:
    """Download an image from *url* to *dest*. Returns True on success."""
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        with open(dest, "wb") as f:
            f.write(resp.content)
        if log_callback:
            log_callback(f"  ✓ Saved {os.path.basename(dest)}")
        return True
    except Exception as exc:
        if log_callback:
            log_callback(f"  ✗ Failed to download {os.path.basename(dest)}: {exc}")
        return False


def download_artwork(
    media_result: MediaResult,
    dest_dir: str,
    log_callback: Optional[Callable[[str], None]] = None,
) -> dict:
    """Download poster and fanart for a movie/TV show.

    Downloads to *dest_dir*:
    - poster.jpg  (w500 quality)
    - fanart.jpg  (original quality)

    Returns dict with paths: ``{"poster": path_or_None, "fanart": path_or_None}``.
    """
    os.makedirs(dest_dir, exist_ok=True)
    result: dict[str, Optional[str]] = {"poster": None, "fanart": None}

    if log_callback:
        log_callback("Downloading artwork…")

    # Poster
    if media_result.poster_path:
        poster_url = f"{TMDB_IMAGE_BASE}/w500{media_result.poster_path}"
        poster_dest = os.path.join(dest_dir, "poster.jpg")
        if _download_image(poster_url, poster_dest, log_callback):
            result["poster"] = poster_dest
    else:
        if log_callback:
            log_callback("  ✗ No poster available on TMDb")

    # Fanart / backdrop
    backdrop_path = _fetch_backdrop_path(media_result.tmdb_id, media_result.media_type)
    if backdrop_path:
        fanart_url = f"{TMDB_IMAGE_BASE}/original{backdrop_path}"
        fanart_dest = os.path.join(dest_dir, "fanart.jpg")
        if _download_image(fanart_url, fanart_dest, log_callback):
            result["fanart"] = fanart_dest
    else:
        if log_callback:
            log_callback("  ✗ No fanart/backdrop available on TMDb")

    return result


def create_nfo(
    media_result: MediaResult,
    dest_dir: str,
    log_callback: Optional[Callable[[str], None]] = None,
) -> str:
    """Create a Kodi/Jellyfin-compatible NFO file.

    For movies creates ``movie.nfo``; for TV shows creates ``tvshow.nfo``.

    Returns the path to the created NFO file.
    """
    os.makedirs(dest_dir, exist_ok=True)

    is_movie = media_result.media_type == "movie"
    root_tag = "movie" if is_movie else "tvshow"
    nfo_name = "movie.nfo" if is_movie else "tvshow.nfo"

    root = ET.Element(root_tag)
    ET.SubElement(root, "title").text = media_result.title
    ET.SubElement(root, "year").text = str(media_result.year) if media_result.year else ""
    ET.SubElement(root, "plot").text = media_result.overview or ""
    ET.SubElement(root, "tmdbid").text = str(media_result.tmdb_id)
    uid = ET.SubElement(root, "uniqueid", type="tmdb")
    uid.text = str(media_result.tmdb_id)

    tree = ET.ElementTree(root)
    nfo_path = os.path.join(dest_dir, nfo_name)
    ET.indent(tree, space="  ")
    tree.write(nfo_path, encoding="unicode", xml_declaration=True)

    if log_callback:
        log_callback(f"  ✓ Created {nfo_name}")

    return nfo_path


def scrape_and_save(
    disc_name: str,
    dest_dir: str,
    log_callback: Optional[Callable[[str], None]] = None,
) -> bool:
    """Full scrape: search TMDb, download artwork, create NFO.

    This is the main convenience function called by the pipeline.
    Returns ``True`` on success, ``False`` on failure.
    """
    if log_callback:
        log_callback(f"Searching TMDb for '{disc_name}'…")

    results = search_media(disc_name)
    if not results:
        if log_callback:
            log_callback("No results found on TMDb.")
        return False

    media = results[0]
    if log_callback:
        log_callback(f"Found: {media.title} ({media.year}) [{media.media_type}]")

    # Refresh full details so poster_path is populated
    if media.media_type == "movie":
        details = get_movie_details(media.tmdb_id)
        if details:
            media = details
    else:
        tv = get_tv_details(media.tmdb_id)
        if tv:
            media = MediaResult(
                title=tv["title"],
                year=tv["year"],
                media_type="tv",
                tmdb_id=media.tmdb_id,
                overview=media.overview,
                poster_path=media.poster_path,
            )

    download_artwork(media, dest_dir, log_callback)
    create_nfo(media, dest_dir, log_callback)

    if log_callback:
        log_callback("Scrape complete.")
    return True
