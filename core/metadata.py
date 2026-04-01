"""TMDb metadata integration — queries The Movie Database API for movie/TV metadata."""

from __future__ import annotations

import re
from dataclasses import dataclass

import requests

from config import load_config

BASE_URL = "https://api.themoviedb.org/3"


@dataclass
class MediaResult:
    title: str
    year: int | None
    media_type: str  # "movie" or "tv"
    tmdb_id: int
    overview: str
    poster_path: str | None


@dataclass
class EpisodeInfo:
    season_number: int
    episode_number: int
    name: str


def _get_api_key() -> str | None:
    """Load the TMDb API key from config, returning None if absent."""
    try:
        cfg = load_config()
        key = cfg.get("tmdb_api_key", "")
        return key if key else None
    except Exception:
        return None


def clean_disc_name(raw_name: str) -> str:
    """Clean raw disc/volume names for better TMDb search results."""
    name = raw_name.replace("_", " ")
    # Remove disc identifiers like DISC_1, DISC 2, D1, D2, etc.
    name = re.sub(r"\bDISC\s*\d+\b", "", name, flags=re.IGNORECASE)
    name = re.sub(r"\bD\d+\b", "", name, flags=re.IGNORECASE)
    # Remove media type tags
    name = re.sub(r"\bBD\b", "", name, flags=re.IGNORECASE)
    name = re.sub(r"\bDVD\b", "", name, flags=re.IGNORECASE)
    name = re.sub(r"\bBLU[\s-]?RAY\b", "", name, flags=re.IGNORECASE)
    # Remove resolution tags
    name = re.sub(r"\b\d{3,4}[pi]\b", "", name, flags=re.IGNORECASE)
    name = re.sub(r"\b4K\b", "", name, flags=re.IGNORECASE)
    # Remove codec/quality tags
    name = re.sub(r"\b(HDR|SDR|REMUX|HEVC|H\.?264|H\.?265|AVC|x264|x265)\b", "", name, flags=re.IGNORECASE)
    # Remove parenthesized year tags like "(2020)" that are clearly metadata
    name = re.sub(r"\(\d{4}\)", "", name)
    # Collapse whitespace and strip
    name = re.sub(r"\s+", " ", name).strip()
    return name.title() if name else raw_name.strip().title()


def search_media(query: str) -> list[MediaResult]:
    """Search TMDb for movies and TV shows matching *query*. Returns up to 10 results."""
    api_key = _get_api_key()
    if not api_key:
        print("Warning: TMDb API key not configured — skipping metadata search.")
        return []

    cleaned = clean_disc_name(query)

    try:
        resp = requests.get(
            f"{BASE_URL}/search/multi",
            params={"api_key": api_key, "query": cleaned},
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception as exc:
        print(f"Warning: TMDb search failed: {exc}")
        return []

    results: list[MediaResult] = []
    for item in data.get("results", []):
        mtype = item.get("media_type")
        if mtype not in ("movie", "tv"):
            continue

        if mtype == "movie":
            title = item.get("title", "")
            date_str = item.get("release_date", "")
        else:
            title = item.get("name", "")
            date_str = item.get("first_air_date", "")

        year = int(date_str[:4]) if date_str and len(date_str) >= 4 else None

        results.append(
            MediaResult(
                title=title,
                year=year,
                media_type=mtype,
                tmdb_id=item.get("id", 0),
                overview=item.get("overview", ""),
                poster_path=item.get("poster_path"),
            )
        )

        if len(results) >= 10:
            break

    return results


def get_movie_details(tmdb_id: int) -> MediaResult | None:
    """Fetch full details for a movie by TMDb ID."""
    api_key = _get_api_key()
    if not api_key:
        print("Warning: TMDb API key not configured.")
        return None

    try:
        resp = requests.get(
            f"{BASE_URL}/movie/{tmdb_id}",
            params={"api_key": api_key},
            timeout=10,
        )
        resp.raise_for_status()
        item = resp.json()
    except Exception as exc:
        print(f"Warning: TMDb movie detail fetch failed: {exc}")
        return None

    date_str = item.get("release_date", "")
    year = int(date_str[:4]) if date_str and len(date_str) >= 4 else None

    return MediaResult(
        title=item.get("title", ""),
        year=year,
        media_type="movie",
        tmdb_id=item.get("id", tmdb_id),
        overview=item.get("overview", ""),
        poster_path=item.get("poster_path"),
    )


def get_tv_details(tmdb_id: int) -> dict | None:
    """Fetch details for a TV show by TMDb ID.

    Returns a dict with keys: title, year, number_of_seasons, seasons.
    """
    api_key = _get_api_key()
    if not api_key:
        print("Warning: TMDb API key not configured.")
        return None

    try:
        resp = requests.get(
            f"{BASE_URL}/tv/{tmdb_id}",
            params={"api_key": api_key},
            timeout=10,
        )
        resp.raise_for_status()
        item = resp.json()
    except Exception as exc:
        print(f"Warning: TMDb TV detail fetch failed: {exc}")
        return None

    date_str = item.get("first_air_date", "")
    year = int(date_str[:4]) if date_str and len(date_str) >= 4 else None

    return {
        "title": item.get("name", ""),
        "year": year,
        "number_of_seasons": item.get("number_of_seasons", 0),
        "seasons": item.get("seasons", []),
    }


def get_season_episodes(tmdb_id: int, season_number: int) -> list[EpisodeInfo]:
    """Fetch episode list for a specific season of a TV show."""
    api_key = _get_api_key()
    if not api_key:
        print("Warning: TMDb API key not configured.")
        return []

    try:
        resp = requests.get(
            f"{BASE_URL}/tv/{tmdb_id}/season/{season_number}",
            params={"api_key": api_key},
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception as exc:
        print(f"Warning: TMDb season fetch failed: {exc}")
        return []

    episodes: list[EpisodeInfo] = []
    for ep in data.get("episodes", []):
        episodes.append(
            EpisodeInfo(
                season_number=ep.get("season_number", season_number),
                episode_number=ep.get("episode_number", 0),
                name=ep.get("name", ""),
            )
        )

    return episodes
