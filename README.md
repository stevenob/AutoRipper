# AutoRipper 🎬

A native macOS app that automates the entire DVD/Blu-ray ripping pipeline: **Rip → Encode → Organize → Scrape metadata** — all hands-free with one click.

Built with **SwiftUI** for a true native macOS experience with sidebar navigation, system colors, and full dark/light mode support. A Python (customtkinter) version is also included.

## Features

- **⚡ Full Auto Mode** — One click to scan, rip, encode, organize, and scrape metadata automatically
- **Smart Title Detection** — Auto-labels scanned titles: 🎬 Main Feature, 🎥 Feature, 📀 Extra, 🎞️ Short Extra, ⏭️ Trailer
- **TMDb Integration** — Automatic movie/TV show identification from disc name, with poster, fanart, and NFO downloads
- **Job Queue** — Rip multiple discs back-to-back; encoding and processing happen in the background
- **Native macOS UI** — Sidebar navigation, grouped sections, system controls, auto-saves settings
- **Scan & Rip** — Detect discs, browse titles with resolution badges (4K/1080p/720p/480p), min duration filter, real-time streaming log
- **HandBrake Encoding** — H.265 presets auto-selected by resolution, Apple VideoToolbox hardware acceleration, audio/subtitle track selection
- **Clean & Organize** — Rename and sort files into structured folders:
  - Movies: `Title (Year)/Title (Year).mkv`
  - TV Shows: `Show/Season 01/Show - S01E01 - Episode Name.mkv`
- **Built-in Artwork & NFO** — Download poster/fanart and create Kodi/Jellyfin-compatible NFO files (movie, TV show, and episode)
- **Discord Notifications** — Single updating job card per title, plus one-shot info/progress/success/error messages
- **NAS Upload** — Auto-copy organized media to NAS with separate movie/TV paths and local cleanup
- **macOS Notifications** — Notification Center alerts (with osascript fallback for debug builds)
- **Auto-eject** — Eject disc after ripping (configurable)
- **Process Management** — All child processes (makemkvcon, HandBrakeCLI) terminate when the app quits
- **File Logging** — Debug logs saved to `~/Library/Logs/AutoRipper/` with daily rotation and 7-day retention
- **99 Unit Tests** — Comprehensive test coverage across services, models, view models, and config

## Pipeline Flow

```
Insert Disc → Scan → Auto-label titles → TMDb lookup
                       ↓
              Select titles (or Full Auto picks the largest)
                       ↓
              Rip → Encode (H.265 by resolution) → Organize → Scrape artwork/NFO
                       ↓                                            ↓
              Discord job card updates at each step         Copy to NAS (optional)
                       ↓
              Eject disc → Ready for next disc
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
- **Xcode 15.3+** (for building the Swift version)
- **[MakeMKV](https://www.makemkv.com/)** installed at `/Applications/MakeMKV.app`
- **[HandBrake CLI](https://handbrake.fr/)** — install via `brew install handbrake`
- **TMDb API key** (free) — [get one here](https://www.themoviedb.org/settings/api)
- **Discord webhook** (optional) — for pipeline notifications
- **NAS path** (optional) — for auto-copy to network storage

## Installation & Running (Swift)

```bash
# Clone the repo
git clone https://github.com/stevenob/AutoRipper.git
cd AutoRipper/AutoRipperSwift

# Build
swift build

# Run
.build/debug/AutoRipper

# Run tests
swift test
```

## Installation & Running (Python)

```bash
cd AutoRipper

# Install dependencies
pip install -r requirements.txt

# Run
python3.13 main.py

# Run tests
python3.13 -m unittest discover -s tests -v
```

### Building a macOS .app bundle (Python)

```bash
pip install pyinstaller
bash build.sh
# → dist/AutoRipper.app

# Create DMG installer
bash create-dmg.sh
# → dist/AutoRipper-Installer.dmg
```

## First-time Setup

1. Launch the app and go to **Settings** in the sidebar
2. Set your **TMDb API key**
3. Verify tool paths: MakeMKV, HandBrake CLI
4. Set your **Output directory** (default: `~/Desktop/Ripped`)
5. Optionally add a **Discord webhook URL** and **NAS paths**
6. Settings auto-save as you type

## Usage

### Full Auto (recommended)

1. Insert a DVD or Blu-ray
2. Check **Full Auto** in the toolbar
3. Click the **Scan Disc** button (becomes **Full Auto**)
4. Walk away — AutoRipper handles everything:
   - Scans and identifies the main feature
   - Rips the largest title
   - Auto-selects H.265 preset by resolution
   - Encodes with HandBrake
   - Organizes into `Title (Year)/Title (Year).mkv`
   - Downloads poster, fanart, and creates NFO file
   - Copies to NAS (if enabled)
   - Ejects the disc
   - Sends Discord notification card
5. Insert next disc — previous jobs encode in the background

### Manual Mode

1. Click **Scan Disc**
2. Review titles — each is auto-labeled (Main Feature, Extra, Trailer, etc.)
3. Use **Select All** / **Deselect All** to choose titles
4. Click **Rip**
5. Switch to **Encode** to pick preset and audio/subtitle tracks
6. Use **Queue** to monitor the pipeline

## Project Structure

```
AutoRipper/
├── AutoRipperSwift/           # Native Swift/SwiftUI app
│   ├── Package.swift
│   ├── AutoRipper/
│   │   ├── AutoRipperApp.swift
│   │   ├── Models/
│   │   │   ├── AppConfig.swift        # Settings (JSON, auto-save)
│   │   │   ├── DiscInfo.swift         # Disc/title models with auto-labeling
│   │   │   ├── Job.swift              # Queue job model
│   │   │   └── MediaResult.swift      # TMDb result models
│   │   ├── Services/
│   │   │   ├── MakeMKVService.swift   # MakeMKV CLI (real-time streaming)
│   │   │   ├── HandBrakeService.swift # HandBrake CLI + auto-preset
│   │   │   ├── TMDbService.swift      # TMDb API (search, details, episodes)
│   │   │   ├── ArtworkService.swift   # Poster/fanart/NFO (movie + episode)
│   │   │   ├── DiscordService.swift   # Webhooks (job cards + one-shots)
│   │   │   ├── OrganizerService.swift # File rename/move (movie + TV)
│   │   │   ├── NotificationService.swift
│   │   │   ├── LogService.swift       # File logging with rotation
│   │   │   └── ProcessTracker.swift   # Child process cleanup on quit
│   │   ├── ViewModels/
│   │   │   ├── RipViewModel.swift
│   │   │   ├── EncodeViewModel.swift
│   │   │   ├── ScrapeViewModel.swift
│   │   │   ├── QueueViewModel.swift
│   │   │   └── SettingsViewModel.swift
│   │   └── Views/
│   │       ├── ContentView.swift      # Sidebar navigation
│   │       ├── RipView.swift
│   │       ├── EncodeView.swift
│   │       ├── ScrapeView.swift
│   │       ├── QueueView.swift
│   │       └── SettingsView.swift
│   └── AutoRipperTests/              # 99 tests
│       ├── Phase1Tests.swift
│       ├── ServiceTests.swift
│       ├── ViewModelTests.swift
│       └── ConfigTests.swift
├── main.py                    # Python entry point
├── config.py                  # Python settings
├── core/                      # Python services
├── gui/                       # Python UI (customtkinter)
├── tests/                     # Python tests
├── build.sh                   # PyInstaller build
├── create-dmg.sh              # DMG builder
└── assets/                    # App icon
```

## License

MIT
