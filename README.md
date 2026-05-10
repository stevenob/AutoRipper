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
| 📺 **Library refresh** | Optional Plex / Jellyfin webhooks fired after publish so newly ripped media shows up in clients within seconds, not minutes |
| 🔁 **Duplicate detection** | Each scanned disc is fingerprinted (title structure + sizes); re-inserting a previously-ripped disc surfaces an "Already ripped on \<date\>" banner |
| ⛔ **Auto-skip duplicates** | In Auto mode, already-ripped discs eject without re-ripping — prevents the auto-eject + drive-auto-close re-rip loop on motorized-tray drives |
| 🚥 **Phase-aware rip startup** | Real-time status during the 20–60 s `makemkvcon mkv` startup gap (drive auth → reading structure → preparing title → ripping) so the UI doesn't look frozen |
| 🚧 **Rip Scratch Dir** | Optional local-SSD scratch dir for slow-NAS setups — keeps bandwidth-hungry rips off the network |
| 🔔 **Notifications** | macOS + Discord alerts for scan, rip, and failures |
| 🔄 **Update Checker** | Checks GitHub Releases on launch |

## How It Works

```
Insert Disc → App detects DVD/Blu-ray
                    │
        ┌── Auto ON ─────→ Scan → Rip selected titles
        │                       → Per-title: encode → organize → scrape → publish to NAS
        │                       → Eject + notify
        │                       → Poll for next disc → repeat
        │
        └── Auto OFF ────→ Scan → Tag intent per title → Rip
```

**v3.6.0 — Local-encode pipeline.** When `Rip Scratch Dir` is configured, encode/organize/scrape all run on local SSD and a single move/copy publishes the finished folder to the NAS at the end. Pre-flight free-space check (`2× source + 1 GB safety`) fails the job up-front if local SSD is too small. Same-volume publishes are server-side renames (instant); cross-volume publishes use byte-verified chunked copy that **preserves the local source** until the swap completes.

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

### Library refresh (Plex / Jellyfin)

After every successful publish, AutoRipper can ping Plex or Jellyfin to immediately scan for the new file — saves the wait for the periodic library sweep.

Settings → **Library** pane:

**Plex**
- URL — e.g., `http://192.168.1.10:32400`
- X-Plex-Token — find in Plex Web → Settings → "View XML" of any item
- Movies / TV Section IDs — open Settings → Manage → Libraries; the URL reads `?source=N`

**Jellyfin**
- URL — e.g., `http://192.168.1.10:8096`
- API Key — Dashboard → API Keys → Generate

Both have **Test refresh** buttons. Empty URLs are silently no-op'd; failures are logged but never block a successful publish.

### Rip Scratch Dir (slow-NAS workaround) + Local-encode pipeline (v3.6.0)

When **Output Directory** lives on a NAS / network share, the raw rip step can be bottlenecked by the network. MakeMKV reads Blu-rays at ~50–70 MB/s and 4K UHD even faster — beyond what a typical Wi-Fi-backed SMB share can absorb, triggering MakeMKV's `MSG:2008` "writes too slow" warnings and throttling.

Setting **Rip Scratch Dir** to a fast local directory (e.g., `~/Movies/RipScratch` or an external SSD) decouples the bandwidth-hungry rip from the network. **As of v3.6.0 the entire pipeline runs locally** when scratch is configured: rip → encode → organize → scrape all happen on local SSD, then a single move/copy publishes the finished folder to the NAS library at the end. Pre-flight free-space check (`2× source + 1 GB safety`) fails the job up-front if local SSD is too small.

Recommended layout for NAS-backed setups:

| Setting | Example | Role |
|---|---|---|
| `Rip Scratch Dir` | `/Volumes/RipSSD` (1 TB external M.2) | Local SSD — entire post-rip pipeline runs here |
| `Output Directory` | `~/Desktop/Ripped` (or any local) | Default landing for rips when scratch is empty |
| `NAS Movies Path` | `/Volumes/ServerShare/Movies` | NAS library — final published location |
| `NAS TV Path` | `/Volumes/ServerShare/TV` | NAS TV library |

Leave `Rip Scratch Dir` empty to keep the legacy behavior (rip writes directly to `Output Directory` and pipeline runs in place).

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
