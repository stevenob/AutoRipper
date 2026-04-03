# AutoRipper 🎬

Insert a disc. Click one button. Walk away.

AutoRipper is a native macOS app that automates DVD and Blu-ray ripping — scan, rip, encode, organize, scrape artwork, copy to NAS, and eject. All hands-free.

Built with Swift and SwiftUI for macOS 14+.

## What It Does

| | |
|---|---|
| ⚡ **Full Auto** | One click: scan → rip → encode → organize → artwork → NAS → eject |
| 🎬 **Smart Detection** | Auto-detects DVD or Blu-ray, labels Main Feature vs Extras vs Trailers |
| 🔍 **TMDb Lookup** | Identifies the movie from disc name, downloads poster + fanart + NFO |
| 🎚️ **H.265 Encoding** | Auto-selects preset by resolution with Apple VideoToolbox HW acceleration |
| 🔊 **All Tracks** | Keeps all audio + subtitle tracks (soft/passthrough, never burned in) |
| 📂 **Auto-Organize** | Rips into `Movie (Year)/Movie (Year).mkv` |
| 💬 **Discord** | Live-updating job card per title + notifications |
| 💾 **NAS Upload** | Copies to NAS, cleans up local files |
| 🔔 **Notifications** | macOS + Discord alerts for scan, rip, and failures |
| 🔄 **Update Checker** | Checks GitHub Releases on launch |

## How It Works

```
Insert Disc → App detects DVD/Blu-ray
                    │
        ┌── Full Auto ON ──→ Scan → Rip main feature
        │                         → Scrape artwork + NFO
        │                         → Encode H.265
        │                         → Copy to NAS
        │                         → Eject + notify
        │
        └── Manual ────────→ Scan → Pick titles → Rip only
```

### Auto-Selected Presets

| Disc | Preset |
|------|--------|
| DVD 480p | H.265 MKV 480p30 |
| DVD PAL 576p | H.265 MKV 576p25 |
| Blu-ray 720p | H.265 MKV 720p30 |
| Blu-ray 1080p | H.265 Apple VideoToolbox 1080p ⚡ |
| 4K UHD 2160p | H.265 Apple VideoToolbox 2160p 4K ⚡ |

## Install

1. Download **AutoRipper-Installer.dmg** from the [latest release](https://github.com/stevenob/AutoRipper/releases/latest)
2. Drag **AutoRipper** to **Applications**
3. First launch: right-click → **Open**

### Dependencies

```bash
# MakeMKV — https://www.makemkv.com/download/
# HandBrake CLI
brew install handbrake
```

## Setup

Click ⚙ in the bottom bar:

1. Enter your **TMDb API key** ([free](https://www.themoviedb.org/settings/api))
2. Verify **MakeMKV** and **HandBrake CLI** paths
3. Set **output directory**
4. Optionally add **Discord webhook** and **NAS paths**

Settings save instantly.

## Usage

### Full Auto

1. Insert disc — app detects type and name
2. Check **☑ Full Auto**, set **Skip under** duration
3. Click the big button
4. Insert next disc when it ejects

### Manual

1. Uncheck Full Auto
2. Click **Scan DVD** / **Scan Blu-ray**
3. Select titles, click **Rip**

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| ⌘R | Rip |
| ⌘D | Eject |
| ⌘. | Abort |
| ⌘, | Settings |

## Build from Source

```bash
git clone https://github.com/stevenob/AutoRipper.git
cd AutoRipper
bash build-swift.sh
# Tests → release build → sign → DMG → GitHub release
```

## Architecture

```
AutoRipperSwift/AutoRipper/
├── AutoRipperApp.swift      App entry, quit-on-close, menu
├── Models/                  AppConfig (UserDefaults), DiscInfo, Job, MediaResult
├── Services/                MakeMKV, HandBrake, TMDb, Discord, Artwork,
│                            Organizer, Notifications, ProcessTracker, UpdateService
├── ViewModels/              RipViewModel, QueueViewModel
└── Views/                   ContentView (single screen), SettingsView (sheet)

AutoRipperTests/             85 tests
```

## Requirements

- macOS 14+ (Apple Silicon recommended)
- [MakeMKV](https://www.makemkv.com/) + [HandBrake CLI](https://handbrake.fr/)
- [TMDb API key](https://www.themoviedb.org/settings/api) (free)

## License

MIT
