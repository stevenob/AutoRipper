# AutoRipper 🎬

A native macOS app that automates DVD/Blu-ray ripping: **Rip → Encode → Organize → Scrape metadata** — hands-free with one click.

Built with **SwiftUI** for a native macOS experience — sidebar navigation, system colors, dark/light mode.

## Features

- **⚡ Full Auto Mode** — Toggle on, click Scan, walk away. Scans disc, rips the main feature, encodes with H.265, organizes, scrapes artwork/NFO, copies to NAS, ejects
- **Manual Rip Mode** — Full Auto off: scan, pick titles, rip raw MKV files without encoding
- **Smart Title Detection** — Auto-labels titles after scan: 🎬 Main Feature, 🎥 Feature, 📀 Extra, 🎞️ Short Extra, ⏭️ Trailer
- **Min Duration Filter** — Titles below the threshold are hidden from scan results entirely
- **TMDb Integration** — Auto-identifies movie/TV name from disc, downloads poster, fanart, and NFO
- **Job Queue** — Rip the next disc while previous titles encode in the background
- **Native macOS UI** — Sidebar navigation, GroupBox sections, real-time streaming log, auto-saving settings
- **HandBrake Encoding** — H.265 presets auto-selected by resolution, Apple VideoToolbox HW acceleration, audio/subtitle track selection
- **File Organization** — Movies: `Title (Year)/Title (Year).mkv` · TV: `Show/Season 01/Show - S01E01.mkv`
- **Artwork & NFO** — Kodi/Jellyfin-compatible poster, fanart, movie/TV/episode NFO from TMDb
- **Discord Notifications** — Updating job card per title + one-shot info/progress/success/error
- **NAS Upload** — Separate movie/TV paths, copies organized folder, cleans up local files
- **Process Management** — All child processes terminate on app quit
- **99 Unit Tests** — Services, models, view models, and config

## Pipeline Flow

```
                    ┌─── Full Auto ON ───────────────────────────────┐
                    │                                                │
Insert Disc → Scan → Auto-label + TMDb lookup                       │
                    │                                                │
                    ├─── Full Auto ON ──→ Rip largest title ─────────┤
                    │                         ↓                      │
                    │                    Encode (H.265 by res)       │
                    │                         ↓                      │
                    │                    Organize + Scrape artwork   │
                    │                         ↓                      │
                    │                    Copy to NAS (optional)      │
                    │                         ↓                      │
                    │                    Eject + Discord notify      │
                    │                                                │
                    └─── Full Auto OFF ─→ Select titles → Rip only ─┘
                                          (raw MKV saved to disk)
```

### Encoding Presets by Resolution

| Source | Resolution | Auto-selected Preset |
|--------|-----------|---------------------|
| DVD | 480p | H.265 MKV 480p30 |
| DVD PAL | 576p | H.265 MKV 576p25 |
| Blu-ray | 720p | H.265 MKV 720p30 |
| Blu-ray | 1080p | H.265 Apple VideoToolbox 1080p ⚡ |
| 4K UHD | 2160p | H.265 Apple VideoToolbox 2160p 4K ⚡ |

⚡ = Hardware-accelerated via Apple Silicon

## Requirements

- **macOS 14+** (Sonoma or later, Apple Silicon recommended)
- **[MakeMKV](https://www.makemkv.com/)** installed at `/Applications/MakeMKV.app`
- **[HandBrake CLI](https://handbrake.fr/)** — install via `brew install handbrake`
- **TMDb API key** (free) — [get one here](https://www.themoviedb.org/settings/api)
- **Discord webhook** (optional) — pipeline notifications
- **NAS path** (optional) — auto-copy to network storage

## Installation

### Download (recommended)

1. Download **AutoRipper-Installer.dmg** from the [latest release](https://github.com/stevenob/AutoRipper/releases/latest)
2. Open the DMG and drag **AutoRipper** to **Applications**
3. First launch: right-click the app → **Open** (required once for ad-hoc signed apps)

### Install dependencies

```bash
# MakeMKV — install from https://www.makemkv.com/download/

# HandBrake CLI
brew install handbrake
```

### Build from source

Requires Xcode 15.3+.

```bash
git clone https://github.com/stevenob/AutoRipper.git
cd AutoRipper
bash build-swift.sh
# → dist/AutoRipper.app (2.4MB, code-signed)

# Install
cp -r dist/AutoRipper.app /Applications/
```

### Run tests

```bash
cd AutoRipperSwift && swift test
# 99 tests, 0 failures
```

## Legacy Python Version

A Python (customtkinter) version is also included:

```bash
pip install -r requirements.txt
python3.13 main.py
```

Build standalone `.app`: `bash build.sh` · DMG installer: `bash create-dmg.sh`

## First-time Setup

1. Click **Settings** in the sidebar
2. Set your **TMDb API key**
3. Verify **MakeMKV** and **HandBrake CLI** paths
4. Set **Output directory** (default: `~/Desktop/Ripped`)
5. Set **Min Duration** to filter out short extras (e.g. 1800 = 30 min)
6. Optionally add **Discord webhook** and **NAS paths**
7. Settings auto-save as you change them

## Usage

### Full Auto (recommended)

1. Insert a disc
2. Check **☑ Full Auto** in the toolbar
3. Click the big **Full Auto** button
4. Walk away — AutoRipper:
   - Scans and identifies the disc via TMDb
   - Auto-labels titles (Main Feature, Extra, Trailer)
   - Rips the largest title above min duration
   - Encodes with the best H.265 preset for the resolution
   - Organizes into `Movie (Year)/Movie (Year).mkv`
   - Downloads poster, fanart, creates NFO
   - Copies to NAS (if enabled), cleans up local files
   - Ejects the disc
   - Sends a Discord notification card
5. Insert next disc — previous encode runs in the background queue

### Manual Rip

1. Uncheck **Full Auto**
2. Click **Scan Disc**
3. Review titles — short extras are hidden by min duration filter
4. Use **Select All** / **Deselect All** or click individual checkboxes
5. Click **Rip** — saves raw MKV files to output directory (no encoding)
6. Use the **Encode** tab separately to encode specific files with custom presets and track selection

## Project Structure

```
AutoRipper/
├── AutoRipperSwift/              # Native SwiftUI app
│   ├── Package.swift
│   ├── AutoRipper/
│   │   ├── AutoRipperApp.swift   # App entry + quit on window close
│   │   ├── Models/               # AppConfig, DiscInfo, Job, MediaResult
│   │   ├── Services/             # MakeMKV, HandBrake, TMDb, Discord, etc.
│   │   ├── ViewModels/           # State + logic per screen
│   │   └── Views/                # SwiftUI sidebar + 5 screens
│   └── AutoRipperTests/          # 99 tests (4 files)
├── main.py                       # Python entry point (legacy)
├── core/                         # Python services
├── gui/                          # Python UI (customtkinter)
└── tests/                        # Python tests
```

## License

MIT
