# AutoRipper 🎬

A Python GUI app that automates the entire DVD/Blu-ray ripping pipeline: **Rip → Encode → Organize → Scrape metadata** — all hands-free with one click.

## Features

- **⚡ Full Auto Mode** — One click to rip, encode, organize, and scrape metadata automatically
- **Job Queue** — Rip multiple discs back-to-back; encoding and processing happen in the background
- **Scan & Rip** — Detect discs, browse titles with resolution display (4K/1080p/720p/480p), min duration filter, file-size progress with ETA
- **HandBrake Encoding** — H.265 quick presets auto-selected by resolution, Apple VideoToolbox hardware acceleration, audio/subtitle track chooser
- **Auto-detect metadata** — [TMDb](https://www.themoviedb.org/) lookup for movie/TV show titles and years
- **Clean & Organize** — Rename and sort files into structured folders:
  - Movies: `Title (Year)/Title (Year).mkv`
  - TV Shows: `Show/Season 01/Show - S01E01 - Episode Name.mkv`
- **tinyMediaManager** — Optional post-organize scrape for artwork, NFO files, and subtitles
- **Auto-eject** — Eject disc after ripping (configurable)
- **Abort** — Cancel any running operation at any time
- **Persistent Preferences** — Settings auto-save between sessions
- **Streaming Logs** — Real-time output from MakeMKV, HandBrake, and tMM

## Pipeline Flow

```
Insert Disc → Scan → Rip → Encode → Auto-Organize → tMM Scrape
                      └── ⚡ Full Auto runs all steps hands-free
                      └── Job Queue: rip next disc while previous encodes
```

### Encoding Presets by Resolution

| Source | Resolution | Auto-selected Preset |
|--------|-----------|---------------------|
| DVD | 480p | H.265 MKV 480p30 |
| Blu-ray | 1080p | H.265 Apple VideoToolbox 1080p ⚡ |
| 4K UHD | 2160p | H.265 Apple VideoToolbox 2160p 4K ⚡ |

⚡ = Hardware-accelerated via Apple Silicon

## Requirements

- **macOS** (tested on Apple Silicon)
- **Python 3.9+** (Python 3.13 via Homebrew recommended)
- **[MakeMKV](https://www.makemkv.com/)** installed at `/Applications/MakeMKV.app`
- **[HandBrake CLI](https://handbrake.fr/)** — install via `brew install handbrake`
- **TMDb API key** (free) — [get one here](https://www.themoviedb.org/settings/api)
- **[tinyMediaManager](https://www.tinymediamanager.org/)** (optional) — for artwork and NFO scraping

## Installation

```bash
# Clone the repo
git clone https://github.com/stevenob/AutoRipper.git
cd AutoRipper

# Install dependencies
pip install -r requirements.txt

# Install HandBrake CLI (if not already installed)
brew install handbrake
```

## Usage

```bash
python3.13 main.py
```

### First-time setup

1. Open the **Settings** tab
2. Set your **TMDb API key**
3. Verify tool paths: MakeMKV, HandBrake, tinyMediaManager
4. Set your **Output directory** (default: `~/Desktop/Ripped`)
5. Click **Save Settings**
6. Adjust **Preferences** (auto-saved): min duration, auto-eject, HandBrake preset, media type

### Full Auto (recommended)

1. Insert a DVD or Blu-ray
2. Click **Scan Disc**
3. Click **⚡ Full Auto**
4. Walk away — AutoRipper handles everything:
   - Rips the largest title
   - Encodes with your default HandBrake preset
   - Organizes into `Title (Year)/Title (Year).mkv`
   - Runs tinyMediaManager to scrape metadata
   - Ejects the disc when done

### Manual Mode

Use **Rip Selected** instead to control each step individually. Each tab (Rip, Encode, Organize, tMM) can be used independently.

## Running Tests

```bash
python3.13 -m unittest discover -s tests -v
```

## Project Structure

```
AutoRipper/
├── main.py              # Entry point
├── config.py            # Settings & preferences (JSON persistence)
├── requirements.txt     # Python dependencies
├── core/
│   ├── disc.py          # Disc/title data models
│   ├── makemkv.py       # MakeMKV CLI wrapper
│   ├── handbrake.py     # HandBrake CLI wrapper
│   ├── metadata.py      # TMDb API integration
│   ├── organizer.py     # File renaming & folder organization
│   ├── tmm.py           # tinyMediaManager CLI wrapper
│   └── job_queue.py     # Background job queue for multi-disc pipeline
├── gui/
│   ├── app.py           # Main application window & settings
│   ├── rip_tab.py       # Disc scanning & ripping UI
│   ├── encode_tab.py    # HandBrake encoding UI
│   ├── metadata_tab.py  # Manual metadata & organize UI
│   ├── tmm_tab.py       # tinyMediaManager UI
│   └── queue_tab.py     # Job queue status UI
└── tests/               # Unit tests (49 tests, all mocked)
```

## License

MIT
