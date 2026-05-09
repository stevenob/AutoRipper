# AutoRipper 🎬

Insert a disc. Click one button. Walk away.

AutoRipper is a native macOS app that automates DVD and Blu-ray ripping — scan, rip, encode, organize, scrape artwork, copy to NAS, and eject. All hands-free.

Built with Swift and SwiftUI for macOS 14+.

## What It Does

| | |
|---|---|
| ⚡ **Auto** | One toggle: insert disc → app rips, encodes, organizes, scrapes, uploads, ejects → polls for the next disc → repeat. Feed it a stack and walk away. |
| ⏯️ **Auto-close tray** | Drop a disc on the open tray and walk away — app sends `drutil tray close` on scan/auto and during the auto-mode poll loop. No-op on drives without soft-close. |
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
| 🚧 **Rip Scratch Dir** | Optional local-SSD scratch dir for slow-NAS setups — keeps bandwidth-hungry rips off the network |
| 🔔 **Notifications** | macOS + Discord alerts for scan, rip, and failures |
| 🔄 **Update Checker** | Checks GitHub Releases on launch |

## How It Works

```
Insert Disc → App detects DVD/Blu-ray
                    │
        ┌── Auto ON ─────→ Scan → Rip selected titles
        │                       → Per-title: stage → encode → organize → scrape → NAS upload
        │                       → Eject + notify
        │                       → Poll for next disc → repeat
        │
        └── Auto OFF ────→ Scan → Tag intent per title → Rip
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
4. Optionally set a **Rip Scratch Dir** (recommended when output lives on a slow NAS — see below)
5. Optionally add **Discord webhook** and **NAS paths**

Settings save instantly.

### Rip Scratch Dir (slow-NAS workaround)

When **Output Directory** lives on a NAS / network share, the raw rip step can be bottlenecked by the network. MakeMKV reads Blu-rays at ~50–70 MB/s and 4K UHD even faster — beyond what a typical Wi-Fi-backed SMB share can absorb, triggering MakeMKV's `MSG:2008` "writes too slow" warnings and throttling.

Setting **Rip Scratch Dir** to a fast local directory (e.g., `~/Movies/RipScratch`) decouples the bandwidth-hungry rip from the network. Each title rips to local SSD, then `StagingService` copies it to `<outputDir>/<folderName>/` with byte-for-byte verification before the encode/organize/scrape pipeline picks it up.

Recommended layout for NAS-backed setups:

| Setting | Example | Role |
|---|---|---|
| `Rip Scratch Dir` | `~/Movies/RipScratch` | Local SSD — temp landing for raw rips |
| `Output Directory` | `/Volumes/ServerShare/Downloaded` | NAS — encode/organize/scrape working dir |
| `NAS Movies Path` | `/Volumes/ServerShare/Movies` | NAS — final library |

Leave `Rip Scratch Dir` empty to keep the legacy behavior (rip writes directly to `Output Directory`).

## Usage

### Auto

1. Insert disc — app detects type and name
2. Check **☑ Auto**, set **Skip under** duration
3. Click the big button
4. Walk away. The app rips → stages → encodes → organizes → scrapes → uploads → ejects, then polls for the next disc and does it all again. Click **Abort** to stop the loop.

### Manual: collections, editions, double features

1. Uncheck Auto
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
│                            JobIntent, MediaResult, InFlightRip (crash-recovery state)
├── Services/                MakeMKV, HandBrake (preset validate, disk-space pre-flight,
│                            stderr-tail on failure), TMDb, Discord, Artwork,
│                            Organizer ({edition-X} naming), Notifications,
│                            ProcessTracker, UpdateService, FileLogger, JobStore,
│                            StagingService (copy+verify cross-volume transfer)
├── ViewModels/              RipViewModel (per-title intents, batch mode, scratch->output staging),
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
