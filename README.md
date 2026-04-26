# AutoRipper 🎬

Insert a disc. Click one button. Walk away.

AutoRipper is a native macOS app that automates DVD and Blu-ray ripping — scan, rip, encode, organize, scrape artwork, copy to NAS, and eject. All hands-free.

Built with Swift and SwiftUI for macOS 14+.

## What It Does

| | |
|---|---|
| ⚡ **Full Auto** | One click: scan → rip → encode → organize → artwork → NAS → eject |
| 📚 **Batch Mode** | Rip → eject → wait for next disc → repeat. Feed it a stack and walk away. |
| 🎬 **Smart Detection** | Auto-detects DVD or Blu-ray, labels Main Feature vs Extras vs Trailers |
| 🎯 **Per-Title Intent** | Mark each title as Movie / Episode / Edition / Extra — collections, double features, and director's cuts all handled correctly |
| 🎞️ **Editions** | Theatrical / Unrated / Director's Cut / Extended / Final Cut → Plex/Jellyfin `{edition-X}` filenames in a shared movie folder |
| 🔍 **TMDb Lookup** | Identifies each title independently — collection discs (Saw 1+2+3) get per-title TMDb search |
| 🎚️ **H.265 Encoding** | Auto-selects preset by resolution with Apple VideoToolbox HW acceleration. Disk-space pre-flight check. |
| 🔊 **All Tracks** | Keeps all audio + subtitle tracks (soft/passthrough, never burned in) |
| 📂 **Auto-Organize** | Movies → `Movie (Year)/Movie (Year).mkv`. Editions share the parent folder. |
| 📋 **Persistent Queue + History** | Survives restarts, mid-flight jobs auto-recover as failed, retry with one click |
| 🔬 **Per-Job Logs** | HandBrake stdout/stderr captured per job; tap any row to expand and diagnose failures |
| 💬 **Discord** | Live-updating job card per title + notifications |
| 💾 **NAS Upload** | Copies to NAS, cleans up local files |
| 🔔 **Notifications** | macOS + Discord alerts for scan, rip, and failures |
| 🔄 **Update Checker** | Checks GitHub Releases on launch |

## How It Works

```
Insert Disc → App detects DVD/Blu-ray
                    │
        ┌── Full Auto ON ──→ Scan → Rip selected titles
        │                         → Per-title: encode → organize → scrape → NAS
        │                         → Eject + notify
        │                         (Batch Mode → loop to next disc)
        │
        └── Manual ────────→ Scan → Tag intent per title → Rip
```

### Auto-Selected Presets

| Disc | Preset |
|------|--------|
| DVD 480p | H.265 MKV 480p30 |
| DVD PAL 576p | H.265 MKV 576p25 |
| Blu-ray 720p | H.265 MKV 720p30 |
| Blu-ray 1080p | H.265 Apple VideoToolbox 1080p ⚡ |
| 4K UHD 2160p | H.265 Apple VideoToolbox 2160p 4K ⚡ |

Preset names are validated against `HandBrakeCLI --preset-list` before encoding starts.

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

Open **Settings** (⌘,):

1. Enter your **TMDb API key** ([free](https://www.themoviedb.org/settings/api))
2. Verify **MakeMKV** and **HandBrake CLI** paths
3. Set **output directory**
4. Optionally add **Discord webhook** and **NAS paths**

Settings save instantly.

## Usage

### Full Auto

1. Insert disc — app detects type and name
2. Check **☑ Full Auto** (and optionally **☑ Batch** to loop), set **Skip under** duration
3. Click the big button
4. Insert next disc when it ejects (or sit back if Batch is on)

### Manual: collections, editions, double features

1. Uncheck Full Auto
2. Click **Scan DVD** / **Scan Blu-ray**
3. For each title, set the **Intent** column:
   - **Movie** — type a search override in the inline field if it's a different movie than the disc name (collection discs)
   - **Edition** — pick the edition label (Theatrical / Unrated / Director's Cut / Extended / Final Cut). All editions of the same movie share one folder.
   - **Episode** — current placeholder; full TV support coming in v3.1
   - **Extra** — keeps raw rip, skips encode/organize/scrape
4. Click **Rip & Encode**

### Queue & History

The sidebar has three tabs:

- **Disc** — scan and rip
- **Queue** — live progress per job, tap to expand HandBrake log, retry failed jobs
- **History** — searchable past jobs, filter by status, reveal in Finder, remove from history

History retention is configurable (default 30 days).

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| ⌘R | Rip |
| ⌘D | Eject |
| ⌘. | Abort (also exits Batch Mode) |
| ⌘, | Settings |
| ⇧⌘O | Open Ripped folder |

## Logs

Persistent log: `~/Library/Logs/AutoRipper/autoripper.log` (rotates at 5 MB).

Per-job logs are also captured into the queue/history rows — tap to expand.

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
├── Models/                  AppConfig, DiscInfo, Job (Codable, intent + edition),
│                            JobIntent, MediaResult
├── Services/                MakeMKV, HandBrake (preset validate, disk-space pre-flight,
│                            stderr-tail on failure), TMDb, Discord, Artwork,
│                            Organizer ({edition-X} naming), Notifications,
│                            ProcessTracker, UpdateService, FileLogger, JobStore
├── ViewModels/              RipViewModel (per-title intents, batch mode),
│                            QueueViewModel (persistent, retry, per-job logs)
└── Views/                   ContentView (NavigationSplitView sidebar),
                             QueueView, HistoryView, SettingsView
```

State persistence: `~/Library/Application Support/AutoRipper/jobs.json` (atomic writes on every change).

## Requirements

- macOS 14+ (Apple Silicon recommended)
- [MakeMKV](https://www.makemkv.com/) + [HandBrake CLI](https://handbrake.fr/)
- [TMDb API key](https://www.themoviedb.org/settings/api) (free)

## Roadmap

- **v3.1** — Real TV series support (show/season/episode picker, episode-level TMDb), Sparkle in-app updates, generic outbound webhooks, disc fingerprinting for duplicate detection.

## License

MIT
