# AutoRipper 🎬

A Python GUI app that wraps [MakeMKV](https://www.makemkv.com/) to rip DVDs/Blu-rays, auto-detect titles via TMDb, and organize files into a clean folder structure.

## Features

- **Scan & Rip** — Detect discs, browse titles (duration, size, chapters), and rip selected tracks with a progress bar
- **Auto-detect metadata** — Search [TMDb](https://www.themoviedb.org/) for movie/TV show info (title, year, season, episode)
- **Clean & Organize** — Rename and sort files into structured folders:
  - Movies: `Title (Year)/Title (Year).mkv`
  - TV Shows: `Show/Season 01/Show - S01E01 - Episode Name.mkv`
- **Configurable** — Set output directory, TMDb API key, and MakeMKV path via the Settings tab

## Requirements

- **macOS** (tested on Apple Silicon)
- **Python 3.10+**
- **[MakeMKV](https://www.makemkv.com/)** installed at `/Applications/MakeMKV.app`
- **TMDb API key** (free) — [get one here](https://www.themoviedb.org/settings/api)

## Installation

```bash
# Clone the repo
git clone https://github.com/stevenob/AutoRipper.git
cd AutoRipper

# Install dependencies
pip install -r requirements.txt
```

## Usage

```bash
python main.py
```

### First-time setup

1. Open the **Settings** tab
2. Set your **TMDb API key**
3. Verify the **MakeMKV path** (default: `/Applications/MakeMKV.app/Contents/MacOS/makemkvcon`)
4. Set your **Output directory** (default: `~/Desktop/Ripped`)
5. Click **Save Settings**

### Ripping a disc

1. Insert a DVD or Blu-ray
2. Go to the **Rip** tab and click **Scan Disc**
3. Select the titles you want to rip
4. Click **Rip Selected** and wait for completion

### Organizing files

1. After ripping, AutoRipper switches to the **Organize** tab
2. Click **Search TMDb** to auto-detect the title
3. Select the correct match or manually enter the title
4. Choose **Movie** or **TV Show** and fill in details
5. Click **Preview** to verify the destination path
6. Click **Organize** to move the file

## Project Structure

```
AutoRipper/
├── main.py              # Entry point
├── config.py            # Settings (output dir, API key, MakeMKV path)
├── requirements.txt     # Python dependencies
├── core/
│   ├── disc.py          # Disc/title data models
│   ├── makemkv.py       # MakeMKV CLI wrapper
│   ├── metadata.py      # TMDb API integration
│   └── organizer.py     # File renaming & folder organization
└── gui/
    ├── app.py           # Main application window
    ├── rip_tab.py       # Disc scanning & ripping UI
    └── metadata_tab.py  # Metadata lookup & file organization UI
```

## License

MIT
