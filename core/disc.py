"""Data models for disc information parsed from MakeMKV output."""

from dataclasses import dataclass, field


@dataclass
class TitleInfo:
    id: int
    name: str
    duration: str
    size_bytes: int
    chapters: int
    file_output: str


@dataclass
class DiscInfo:
    name: str
    type: str  # "dvd" or "bluray"
    titles: list[TitleInfo] = field(default_factory=list)
