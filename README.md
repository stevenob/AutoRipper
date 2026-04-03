# AutoRipper 🎬

A modern macOS GUI app that automates the entire DVD/Blu-ray ripping pipeline: **Rip → Encode → Organize → Scrape metadata** — all hands-free with one click.

Built with [customtkinter](https://github.com/TomSchimansky/CustomTkinter) for a native macOS look with automatic dark/light mode support.

## Features

- **⚡ Full Auto Mode** — One click to rip, encode, organize, and scrape metadata automatically
- **Job Queue** — Rip multiple discs back-to-back; encoding and processing happen in the background (auto-prunes completed jobs)
- **Modern UI** — Native macOS appearance with dark/light mode, rounded buttons, and clean design
- **Scan & Rip** — Detect discs, browse titles with resolution display (4K/1080p/720p/480p), min duration filter, file-size progress with ETA
- **HandBrake Encoding** — H.265 quick presets auto-selected by resolution, Apple VideoToolbox hardware acceleration, audio/subtitle track chooser
- **Auto-detect metadata** — [TMDb](https://www.themoviedb.org/) lookup for movie/TV show titles and years
- **Clean & Organize** — Rename and sort files into structured folders:
  - Movies: `Title (Year)/Title (Year).mkv`
  - TV Shows: `Show/Season 01/Show - S01E01 - Episode Name.mkv`
- **tinyMediaManager** — Optional post-organize scrape for artwork, NFO files, and subtitles
- **Built-in Artwork & NFO** — Download poster/fanart and create Kodi/Jellyfin-compatible NFO files directly from TMDb (no Java needed)
- **Auto-eject** — Eject disc after ripping (configurable), plus manual eject button
- **Abort** — Cancel any running operation at any time
- **Persistent Preferences** — Settings auto-save between sessions
- **Streaming Logs** — Real-time output from MakeMKV and HandBrake
- **File Logging** — Debug logs saved to `~/Library/Logs/AutoRipper/` with daily rotation
- **macOS Notifications** — Notification Center alerts for job completion and failures
- **Native Menu Bar** — About dialog, ⌘, for Settings, ⌘Q to quit

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
- **[tinyMediaManager](https://www.tinymediamanager.org/)** (optional) — for advanced artwork and NFO scraping
- **Discord webhook** (optional) — for pipeline notifications (single updating card per title)
- **NAS Upload** (optional) — auto-copy organized media to NAS with local cleanup

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

## Building the App

To build a standalone macOS `.app` bundle (double-click to launch, shows in Dock):

```bash
pip install pyinstaller
bash build.sh
```

The app bundle will be at `dist/AutoRipper.app`. To install:

```bash
cp -r dist/AutoRipper.app /Applications/
```

To create a drag-and-drop DMG installer:

```bash
bash create-dmg.sh
# → dist/AutoRipper-Installer.dmg
```

## Usage

```bash
python3.13 main.py
```

### First-time setup

1. Open the **Settings** tab
2. Set your **TMDb API key**
3. Verify tool paths: MakeMKV, HandBrake
4. Set your **Output directory** (default: `~/Desktop/Ripped`)
5. Optionally add a **Discord webhook URL** for notifications
6. Click **Save Settings**
7. Adjust **Preferences** (auto-saved): min duration, auto-eject, HandBrake preset, media type

### Full Auto (recommended)

1. Insert a DVD or Blu-ray
2. Click **Scan Disc**
3. Click **⚡ Full Auto**
4. Walk away — AutoRipper handles everything:
   - Rips the largest title
   - Auto-selects H.265 preset by resolution (HW-accelerated for 1080p/4K)
   - Encodes with HandBrake
   - Organizes into `Title (Year)/Title (Year).mkv`
   - Downloads poster, fanart, and creates NFO file
   - Ejects the disc when done
   - Sends a single Discord notification card that updates at each step
5. Insert next disc and repeat — previous jobs encode in the background

### Manual Mode

Use **Rip Selected** instead to control each step individually. Tabs: Rip, Encode, Scrape, Queue, Settings.

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
├── build.sh             # PyInstaller → .app bundle
├── create-dmg.sh        # DMG installer builder
├── AutoRipper.spec      # PyInstaller spec
├── assets/              # App icon (.icns, .png)
├── core/
│   ├── disc.py          # Disc/title data models
│   ├── makemkv.py       # MakeMKV CLI wrapper
│   ├── handbrake.py     # HandBrake CLI wrapper
│   ├── metadata.py      # TMDb API integration
│   ├── organizer.py     # File renaming & folder organization
│   ├── artwork.py       # Poster/fanart download & NFO creation
│   ├── discord_notify.py # Discord webhook (single updating card per job)
│   ├── macos_notify.py  # macOS Notification Center alerts
│   ├── logger.py        # File logging to ~/Library/Logs/AutoRipper
│   └── job_queue.py     # Background job queue for multi-disc pipeline
├── gui/                 # customtkinter UI (dark/light mode)
│   ├── app.py           # Main window, menu bar, settings, pipeline orchestration
│   ├── rip_tab.py       # Disc scanning & ripping
│   ├── encode_tab.py    # HandBrake encoding with H.265 presets
│   ├── scrape_tab.py    # Artwork & NFO scraper
│   └── queue_tab.py     # Job queue status
└── tests/               # Unit tests (49 tests, all mocked)
```

## License

MIT
