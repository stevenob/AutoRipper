import os
import re
import shutil


_INVALID_FILENAME_CHARS = re.compile(r'[/\\:*?"<>|]')


def clean_filename(name: str) -> str:
    """Strip illegal filename characters and normalize whitespace."""
    name = _INVALID_FILENAME_CHARS.sub("", name)
    name = re.sub(r"\s+", " ", name)
    return name.strip()


def build_movie_path(output_dir: str, title: str, year: int = None) -> str:
    """Build destination path for a movie file."""
    title = clean_filename(title)
    if year is not None:
        folder_name = f"{title} ({year})"
    else:
        folder_name = title
    return os.path.join(output_dir, folder_name, f"{folder_name}.mkv")


def build_tv_path(
    output_dir: str,
    show: str,
    season: int,
    episode: int,
    episode_name: str = None,
) -> str:
    """Build destination path for a TV episode file."""
    show = clean_filename(show)
    filename = f"{show} - S{season:02d}E{episode:02d}"
    if episode_name is not None:
        filename += f" - {clean_filename(episode_name)}"
    filename += ".mkv"
    return os.path.join(output_dir, show, f"Season {season:02d}", filename)


def organize_file(source_path: str, dest_path: str) -> str:
    """Move source_path to dest_path, creating directories and avoiding overwrites.

    Returns the final destination path (may differ from dest_path if a
    conflict suffix was added).
    """
    dest_dir = os.path.dirname(dest_path)
    os.makedirs(dest_dir, exist_ok=True)

    base, ext = os.path.splitext(dest_path)
    final_path = dest_path
    counter = 2
    while os.path.exists(final_path):
        final_path = f"{base} ({counter}){ext}"
        counter += 1

    shutil.move(source_path, final_path)
    return final_path


def preview_organization(source_path: str, dest_path: str) -> dict:
    """Return a preview dict describing what organize_file would do."""
    return {
        "source": source_path,
        "destination": dest_path,
        "directory": os.path.dirname(dest_path),
        "filename": os.path.basename(dest_path),
        "exists": os.path.exists(dest_path),
    }
