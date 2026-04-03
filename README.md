# AutoRipper 🎬

A native macOS app for automated DVD and Blu-ray ripping. Insert a disc, click one button, and AutoRipper handles everything — rip, encode, organize, download artwork, and copy to your NAS.

Built with **Swift** and **SwiftUI** for macOS 14+.

<!-- Add your own screenshots here -->
<!-- ![Rip Tab](assets/screenshots/rip.png) -->
<!-- ![Encode Tab](assets/screenshots/encode.png) -->
<!-- ![Settings](assets/screenshots/settings.png) -->

## Highlights

| | |
|---|---|
| ⚡ **Full Auto** | One click: scan → rip → encode → organize → scrape → NAS → eject |
| 🎬 **Smart Detection** | Auto-labels Main Feature, Extras, Trailers by size and duration |
| 🔍 **TMDb Lookup** | Identifies movies/TV from disc name, downloads poster + fanart + NFO |
| 🎚️ **H.265 Encoding** | Auto-selects preset by resolution, Apple VideoToolbox hardware acceleration |
| 🔊 **All Tracks** | Keeps all audio and subtitle tracks (soft/passthrough, never burned in) |
| 📂 **Auto-Organize** | `Movie (Year)/Movie (Year).mkv` or `Show/Season 01/Show - S01E01.mkv` |
| 💬 **Discord** | Live-updating job card per title + instant notifications |
| 💾 **NAS Upload** | Separate movie/TV paths, copies folder, cleans up local files |
| ⌨️ **Keyboard Shortcuts** | ⌘R Rip, ⌘E Encode, ⌘D Eject, ⌘. Abort |
| 📎 **Drag & Drop** | Drop MKV files onto the Encode tab |
| 🔔 **Notifications** | macOS + Discord alerts for scan, rip, encode, and failures |
| 🔄 **Update Checker** | Checks GitHub Releases on launch, shows banner if newer version exists |

## How It Works

```
                  ┌─── Full Auto ON ────────────────────────────┐
                  │                                              │
Insert Disc → Scan → TMDb lookup + auto-label titles             │
                  │                                              │
                  ├─── Full Auto ──→ Rip main feature ───────────┤
                  │                       ↓                      │
                  │                  Scrape artwork + NFO        │
                  │                       ↓                      │
                  │                  Encode (H.265)              │
                  │                       ↓                      │
                  │                  Organize + NAS copy         │
                  │                       ↓                      │
                  │                  Eject + notify              │
                  │                                              │
                  └─── Manual ─────→ Pick titles → Rip only ────┘
```

### Encoding Presets

| Source | Auto-selected Preset |
|--------|---------------------|
| DVD 480p | H.265 MKV 480p30 |
| DVD PAL 576p | H.265 MKV 576p25 |
| Blu-ray 720p | H.265 MKV 720p30 |
| Blu-ray 1080p | H.265 Apple VideoToolbox 1080p ⚡ |
| 4K UHD 2160p | H.265 Apple VideoToolbox 2160p 4K ⚡ |

⚡ Hardware-accelerated on Apple Silicon

## Install

### Download

1. Grab **AutoRipper-Installer.dmg** from the [latest release](https://github.com/stevenob/AutoRipper/releases/latest)
2. Open the DMG, drag **AutoRipper** to **Applications**
3. First launch: right-click → **Open** (required once for unsigned apps)

### Dependencies

```bash
# MakeMKV — download from https://www.makemkv.com/download/

# HandBrake CLI
brew install handbrake
```

### Build from Source

```bash
git clone https://github.com/stevenob/AutoRipper.git
cd AutoRipper
bash build-swift.sh
# Runs tests → builds release → signs → creates DMG → pushes GitHub release
```

## Setup

1. Open **Settings** in the sidebar
2. Enter your **TMDb API key** ([get one free](https://www.themoviedb.org/settings/api))
3. Verify **MakeMKV** and **HandBrake CLI** paths
4. Set **output directory** and **min duration** (hides short extras)
5. Optionally add **Discord webhook** and **NAS paths**

All settings save instantly — no save button needed.

## Usage

### Full Auto (recommended)

1. Insert disc
2. Check **☑ Full Auto** in the toolbar
3. Click the big **Full Auto** button
4. AutoRipper does the rest — insert the next disc when it ejects

### Manual Rip

1. Uncheck Full Auto, click **Scan Disc**
2. Pick titles (checkboxes, Select All / Deselect All)
3. Click **Rip** — raw MKV files saved to output directory
4. Optionally encode later from the **Encode** tab with custom preset and track selection

## Architecture

```
AutoRipper/
├── AutoRipperSwift/
│   ├── AutoRipper/
│   │   ├── Models/          AppConfig (UserDefaults), DiscInfo, Job, MediaResult
│   │   ├── Services/        MakeMKV, HandBrake, TMDb, Discord, Artwork,
│   │   │                    Organizer, Notifications, Logging, ProcessTracker
│   │   ├── ViewModels/      Rip, Encode, Scrape, Queue
│   │   └── Views/           Sidebar + 5 screens (SwiftUI)
│   └── AutoRipperTests/     95 unit tests
├── VERSION                  Single source of truth for version
├── build-swift.sh           Build → test → sign → DMG → GitHub release
└── assets/                  App icon
```

## Requirements

- macOS 14+ (Sonoma), Apple Silicon recommended
- Xcode 15.3+ (build from source only)
- [MakeMKV](https://www.makemkv.com/)
- [HandBrake CLI](https://handbrake.fr/) (`brew install handbrake`)
- [TMDb API key](https://www.themoviedb.org/settings/api) (free)

## License

MIT
