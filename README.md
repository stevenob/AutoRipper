# AutoRipper 🎬

**Insert a disc. Click one button. Walk away.**

A native macOS app that automates the entire DVD / Blu-ray → Plex pipeline: scan, rip, encode, organize, scrape artwork, publish to NAS, eject — then poll for the next disc. Feed it a stack and walk away.

Built with Swift and SwiftUI for macOS 14+.

---

## Highlights

- **Auto mode** — one toggle, ripping continues disc-after-disc until you stop it
- **TV-on-disc done right** — matches each disc title to its TMDb episode by runtime, lands as `Show/Season 01/Show - S01E01.mkv` (Plex/Jellyfin convention) without manual mapping
- **Drive health diagnostics** — separates drive-side I/O errors from disc-side corruption events, detects offset-clustering across multiple discs to call out a failing drive automatically
- **Bulk re-rip workflow** — mark damaged discs for re-rip, clean them, re-insert; AutoRipper bypasses the duplicate-detection banner once per marked disc
- **Per-disc rules** — match on disc name / type, override preset / intent / drive speed
- **Cleaning guide** built into Settings with concrete disc + lens steps
- **Local-encode pipeline** — encode/organize/scrape all on a local SSD scratch dir, then a single verified copy to NAS at the end (avoids saturating slow Wi-Fi / SMB with the bandwidth-hungry rip stage)
- **Track selection** — per-title audio + subtitle checkboxes feed directly to HandBrake's `--audio` / `--subtitle` filters
- **Library refresh** — Plex / Jellyfin webhooks fired after publish so new media shows up in seconds

---

## Install

1. Download **AutoRipper-Installer.dmg** from the [latest release](https://github.com/stevenob/AutoRipper/releases/latest)
2. Drag **AutoRipper** to **Applications**
3. First launch: right-click → **Open** (Gatekeeper warning, current builds are dev-signed not notarized — see [Updates/SPARKLE.md](Updates/SPARKLE.md) for the v4.0 notarization roadmap)

### Dependencies

```bash
# MakeMKV — https://www.makemkv.com/download/
# HandBrake CLI
brew install handbrake
```

## Setup

Open **Settings** (⌘,):

1. **General** — output directory, optional **Rip Scratch Dir** (recommended for slow-NAS setups)
2. **Tools** — verify MakeMKV + HandBrake CLI paths (Auto-detect button), optional custom HandBrake preset JSON import
3. **TMDb** — paste your [free API key](https://www.themoviedb.org/settings/api)
4. **NAS** — movies + TV paths, optional extras-to-NAS toggle
5. **Library** (optional) — Plex / Jellyfin auto-refresh webhooks
6. **Discord** (optional) — live job cards + failure alerts

Settings save instantly. **Settings → Advanced** has full export / import to JSON for backing up your config or migrating to a new Mac.

---

## Usage

### Auto mode (the headline feature)

1. Insert disc — app detects type + name + tray-closes the drive
2. Check **☑ Auto**
3. Click **Scan & Auto-Rip**
4. Walk away. AutoRipper rips → encodes → organizes → scrapes artwork → publishes to NAS → ejects → polls for the next disc and does it all again

For TV-on-disc, Auto mode picks every clustered-runtime title and auto-numbers them by TMDb episode runtime (see TV story below).

### Manual mode (collections, editions, double features)

1. Uncheck Auto
2. Click **Scan**
3. Per title, set the **Intent** column:
   - **Movie** — type a search override if it's a different movie than the disc name (collection discs like *Saw 1+2+3*)
   - **Edition** — pick the label (Theatrical / Unrated / Director's Cut / Extended / Final Cut). All editions of the same movie share one folder via Plex/Jellyfin `{edition-X}` tags
   - **Episode** — pick the season / episode via TV picker (or let TMDb runtime-matching do it for you)
   - **Extra** — keeps raw rip; published to `<Movie or Show>/extras/` on NAS
4. Per title, optionally untick individual audio / subtitle tracks under the **Tracks** section
5. Click **Rip & Encode**

### Auto-selected presets

| Disc | Default Preset |
|------|----------------|
| DVD 480p | H.265 MKV 480p30 |
| DVD PAL 576p | H.265 MKV 576p25 |
| Blu-ray 720p / 1080p | H.265 Apple VideoToolbox 1080p ⚡ |
| 4K UHD 2160p | H.265 Apple VideoToolbox 2160p 4K ⚡ |

**Custom presets** (Settings → Tools): export from HandBrake.app, import the JSON, AutoRipper passes `--preset-import-file` to every encode. The custom presets show up in the preset picker alongside the built-ins.

---

## Drive Health story

Insert enough damaged discs (or an aging drive) and you'll start seeing MakeMKV errors. AutoRipper splits them into two categories so you can diagnose drive vs disc:

| Category | MakeMKV codes | What it means |
|---|---|---|
| **Read errors** (drive-side) | `MSG:2003` | Laser couldn't read sectors. Slow down drive speed, clean lens, replace drive. |
| **Corruption events** (disc-side) | `MSG:2002`, `MSG:2017`, `MSG:2018` | Data read but failed validation. Clean disc, replace disc. |

### What AutoRipper does with that data

1. **Per-rip pills** in the disc panel — `⚠ 3 read errors` / `✕ 5 corrupt` capsules appear in real-time during a rip
2. **Auto-suggest slower drive speed** when read errors cross a threshold (5), with one-click action button
3. **Per-disc History detail** preserves the counts + the actual byte offsets where errors fired
4. **Settings → Drive Health** aggregates everything across your full History into a single verdict (`healthy` / `someIssues` / `driveSuspect` / `insufficientData`)
5. **Offset clustering finding** — if errors on **multiple different discs** all happen at similar byte offsets, AutoRipper surfaces a red `Errors cluster at ~X GB` card explaining this is strong evidence of a drive laser-tracking fault at that radial position
6. **Main window header badge** mirrors the verdict so you don't have to drill into Settings
7. **Settings → Cleaning** has a built-in step-by-step guide for cleaning discs (microfiber + isopropyl, radial wipe) and the drive lens (commercial lens-cleaning disc)

### Re-rip workflow

When a disc has known errors:

1. Open **History** detail for the problem disc → **Mark for re-rip** (or **Drive Health → Mark all affected discs**)
2. Clean the disc physically
3. Re-insert. AutoRipper suppresses the "Already ripped" banner once, re-rips cleanly, then resumes normal duplicate-detection behavior

---

## TV-on-disc → Plex layout

Discs don't contain standardized season / episode info, but TMDb does. AutoRipper uses it:

1. Disc scan auto-categorizes clustered-runtime titles (18–90 min, 3+ of them) as `.episode`
2. After TMDb resolves the show, AutoRipper fetches the season's episode list **with runtimes**
3. `TVEpisodeMatcher` greedy-pairs each disc title to its closest-duration episode (within 4 min tolerance)
4. Unmatched disc titles auto-demote to `.extra` so they ride the extras-to-NAS path instead of colliding with real episodes
5. Final NAS layout (Plex/Jellyfin convention):

```
<NAS TV path>/<Show Title>/
├── Season 01/
│   ├── <Show> - S01E01.mkv
│   ├── <Show> - S01E02.mkv
│   └── ...
└── extras/
    ├── <Show> - extra-1.mkv
    └── ...
```

Movies follow the same convention: `<Movie Title> (Year)/<Movie Title> (Year).mkv` with editions sharing the parent folder via the `{edition-X}` filename tag. Extras land at `<Movie Title> (Year)/extras/...`.

---

## Per-disc rules

**Settings → Rules** lets you define overrides triggered by disc context. Each rule combines optional match constraints (ANDed) with optional actions (applied):

| Match on | Override |
|---|---|
| Disc name contains `<string>` | HandBrake preset |
| Media type (movie / TV) | Title intent (movie / episode / edition / extra) |
| Disc type (DVD / Blu-ray) | MakeMKV drive read speed |

Order = priority. Two-pane editor with drag-to-reorder.

Example: a rule with `nameContains: "anime"`, `discTypeFilter: "bluray"`, preset override `H.265 MKV 1080p30 Anime` will fire on every anime BD scan and use your custom anime preset automatically.

---

## Local-encode pipeline + slow-NAS setups

MakeMKV reads Blu-rays at ~50–70 MB/s, 4K UHD faster — beyond what most Wi-Fi-backed SMB shares can absorb. Triggers MakeMKV's `MSG:2008` "writes too slow" warnings.

Set **Rip Scratch Dir** to a local SSD path and the entire pipeline (rip → encode → organize → scrape) runs locally. A single verified copy publishes the finished folder to NAS at the end. Pre-flight free-space check refuses the job if local SSD doesn't have `2× source + 1 GB` headroom.

Same-volume publishes are server-side renames (instant); cross-volume publishes use byte-verified chunked copy that **preserves the local source** until the final swap completes — crash-safe.

Recommended layout:

| Setting | Example | Role |
|---|---|---|
| `Rip Scratch Dir` | `/Volumes/RipSSD` | Local SSD — entire pipeline runs here |
| `Output Directory` | `~/Desktop/Ripped` | Default landing when scratch is empty |
| `NAS Movies Path` | `/Volumes/ServerShare/Movies` | Final published location |
| `NAS TV Path` | `/Volumes/ServerShare/TV Shows` | TV library |

---

## Queue + History

The sidebar has three tabs:

- **Disc** — scan and rip
- **Queue** — live progress per job, tap to expand pipeline status + HandBrake log, retry failed jobs
- **History** — searchable past jobs, filter by status, reveal in Finder, mark-for-re-rip, remove from history

History retention is configurable (Settings → History; default 30 days). All state survives restarts via atomic JSON writes; in-flight jobs auto-recover as failed on next launch so you can retry.

---

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| ⌘R | Rip |
| ⌘D | Eject |
| ⌘. | Abort (also exits Auto mode) |
| ⌘, | Settings |
| ⇧⌘O | Open Ripped folder |

---

## Logs

Persistent log: `~/Library/Logs/AutoRipper/autoripper.log` (rotates at 5 MB).

Per-job logs are also captured into the queue / history rows — tap to expand.

---

## Build from source

```bash
git clone https://github.com/stevenob/AutoRipper.git
cd AutoRipper
bash build-swift.sh
# Runs tests → release build → sign → DMG → GitHub release
```

Requires Xcode command-line tools + Apple Development cert in keychain. See [Updates/SPARKLE.md](Updates/SPARKLE.md) for the Sparkle + notarization migration plan.

---

## Architecture

```
AutoRipperSwift/AutoRipper/
├── AutoRipperApp.swift      App entry, quit-on-close, menu
├── Models/                  AppConfig, DiscInfo (incl. DiscAudioTrack /
│                            DiscSubtitleTrack), Job (Codable), JobIntent,
│                            MediaResult, EpisodeInfo, DiscRule,
│                            InFlightRip (crash-recovery state)
├── Services/                MakeMKV, HandBrake, TMDb, Artwork, Organizer
│                            ({edition-X} naming), Discord, Notifications,
│                            ProcessTracker, UpdateService, FileLogger,
│                            JobStore, StagingService, PublishService
│                            (sibling-preserving per-file publish),
│                            ScratchReservationService (concurrency-safe
│                            disk-space ledger), MakeMKVConfigService
│                            (drive-speed persistence), RippedDiscRegistry
│                            (fingerprint dedup), LibraryNotifierService
│                            (Plex/Jellyfin webhooks), SafeFSCleanup
│                            (ownership-aware scratch teardown),
│                            DriveHealthAnalyzer, TVEpisodeMatcher,
│                            DiscFingerprintService
├── ViewModels/              RipViewModel (per-title intents + tracks,
│                            auto-episode numbering, scan→stage→encode),
│                            QueueViewModel (persistent queue, retry,
│                            per-job logs, per-disc workspace isolation)
└── Views/                   ContentView (NavigationSplitView sidebar,
                             Drive Health badge), DiscInfoColumn (scan
                             health banner, track checkboxes), QueueView,
                             SettingsView (10 tabs), CleaningGuideView,
                             RulesPane, TVEpisodePicker
```

State persistence: `~/Library/Application Support/AutoRipper/jobs.json` (atomic writes on every change). User preferences in standard `UserDefaults` under suite `group.com.autoripper`. Custom presets, rules, and re-rip queue all round-trip through the JSON settings export.

300+ unit tests cover the pure logic — parsers, analyzers, file-system safety helpers, rule matching.

---

## Requirements

- macOS 14+ (Apple Silicon recommended; Apple VideoToolbox HW acceleration is a meaningful win)
- [MakeMKV](https://www.makemkv.com/) + [HandBrake CLI](https://handbrake.fr/)
- [TMDb API key](https://www.themoviedb.org/settings/api) (free)
- Optional: NAS for library publish, Plex / Jellyfin for auto-refresh, Discord for job cards

---

## Roadmap

See [Updates/SPARKLE.md](Updates/SPARKLE.md) for the deferred Sparkle + Apple notarization work. The current `UpdateService.swift` ships updates reliably until that lands.

Other candidates: multi-drive support (parallel rip queues), full HandBrake preset GUI editor.

## License

MIT
