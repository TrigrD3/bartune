# BarTune

A lightweight native macOS app that displays real-time karaoke lyrics in the menu bar **to the left of the MacBook notch** — keeping your windows, browser tabs, and screen completely unobstructed.

Supports **Spotify** and **Apple Music** out of the box with no login or API keys required.

## Features

- **Left-of-Notch Menu Bar Placement** — Uses `NSScreen.auxiliaryTopLeftArea` on notched MacBooks so lyrics sit strictly inside the menu bar height.
- **Hover-to-Reveal App Menus** — Choose in Settings between **Cursor Spotlight** (reveals only the menu item under your pointer with an adjustable cutout width) and **Hide Entire Bar** (fades out the strip on hover).
- **Word-by-Word & Line Karaoke Sync** — Fetches word-level **NetEase YRC** lyrics when available and falls back to **LRCLIB** (including enhanced word-level LRC `<mm:ss.xx>` and standard LRC), with AppleScript latency compensation and a manual **Timing Offset** (`-5.0s` to `+5.0s`).
- **GPU-Interpolated Smooth Sweep & Low-CPU Modes** — Smooth left-to-right karaoke highlight with auto-scrolling for long lines and an optional animated equalizer. Switch between **Low CPU (Standard)** and **High Precision (30fps)** in Settings, backed by event-driven playback monitoring and idle timer pause.
- **Album Art Color Themes** — Syncs highlight or backdrop colors to the currently playing album artwork.
- **Custom Typography & Appearance** — Configure font family, weight, font size (`11–15 pt`), and background opacity (`70%–100%`) in Settings (`⌘,`).
- **Japanese → Romaji** — Built-in offline macOS `CFStringTokenizer` converts Japanese lyrics (Kanji, Hiragana, Katakana) to Romaji with an instant toggle.
- **Spotify + Apple Music** — Reads local playback via AppleScript with comma-decimal locale support (`en_ID`, `de_DE`, `uk_UA`, etc.).

## Requirements

- **macOS 13.0 (Ventura)** or later
- **Swift 5.9+** (via Xcode or Xcode Command Line Tools) to build from source
- **Spotify** and/or **Apple Music** desktop app
- **Automation** permission for BarTune to read track metadata and playback position

## Install

### Homebrew (macOS)

```bash
brew install --cask TrigrD3/tap/bartune
```

### Build from Source

```bash
chmod +x build.sh
./build.sh --install
open -a BarTune
```

To build `BarTune.app` locally in the repository without installing to `/Applications`:

```bash
./build.sh
```

## Usage & Settings

Once launched, BarTune runs as a menu bar utility (`LSUIElement`) and automatically follows playback from Spotify or Apple Music.

Open **Settings** (`⌘,`) to customize:
- **Hover Behavior** — *Cursor Spotlight* (with Spotlight Width slider) or *Hide Entire Bar*
- **Color Theme** — Album art–synced or default theme
- **Typography & Appearance** — Font family, weight, size, karaoke sweep toggle, equalizer toggle, Japanese → Romaji toggle, and background opacity
- **Performance & Sync** — *Low CPU (Standard)* vs *High Precision (30fps)* and *Timing Offset*

## Project Structure

```text
Sources/BarTune/
├── main.swift                   # App entry point
├── AppDelegate.swift            # Menu bar status item, Settings shortcut, app lifecycle
├── OverlayWindowController.swift # Left-of-notch overlay window & hover/spotlight masking
├── LyricsOverlayView.swift      # Karaoke sweep rendering, auto-scroll, equalizer UI
├── LyricsState.swift            # Observable state & persisted user preferences
├── SpotifyMonitor.swift         # Event-driven AppleScript playback monitor (Spotify & Apple Music)
├── LyricsFetcher.swift          # NetEase YRC & LRCLIB lyrics fetching and caching
├── Models.swift                 # TrackInfo, LyricLine, WordTimestamp, LRC/YRC parsers
├── AlbumArtColorExtractor.swift # Dominant/accent color extraction from album artwork
├── Romanizer.swift              # Offline Japanese → Romaji conversion via CFStringTokenizer
└── SettingsView.swift           # SwiftUI Settings window
```

## Permissions

On first launch, macOS will prompt you to grant **Automation** access so BarTune can query Spotify or Apple Music. If lyrics do not appear, check **System Settings → Privacy & Security → Automation** and ensure **BarTune** is allowed to control Spotify / Music.
