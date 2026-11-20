<p align="center">
  <img src="docs/logo.png" width="144" height="144" alt="BarTune App Icon" />
</p>

<h1 align="center">BarTune</h1>

<p align="center">
  <strong>Real-time karaoke lyrics in your macOS menu bar — tucked cleanly to the left of the MacBook notch.</strong><br/>
  Zero window overlap. Zero accounts or API keys. Built natively in Swift.
</p>

<p align="center">
  <a href="https://github.com/TrigrD3/bartune/actions/workflows/ci.yml"><img src="https://github.com/TrigrD3/bartune/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/macOS-13.0%2B-black?logo=apple" alt="macOS 13+" />
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License" /></a>
</p>

---

## Why BarTune?

Most desktop lyrics apps float over your editor, browser tabs, or terminal. **BarTune** lives strictly inside the unused menu bar space to the left of your MacBook notch (`NSScreen.auxiliaryTopLeftArea`), smoothly sweeping lyrics in sync with your music — and instantly stepping aside the moment your cursor hovers over app menus.

## Highlights

- **Left-of-Notch Native Placement** — Sits strictly within the macOS menu bar height so your workspace stays 100% unobstructed.
- **Hover-to-Reveal App Menus** — Choose between **Cursor Spotlight** (peeks only the menu item under your pointer with an adjustable cutout width) or **Hide Entire Bar** on hover.
- **Spotify, Apple Music & Browser Music** — Works out of the box with desktop **Spotify** and **Apple Music**, and automatically falls back to **YouTube Music, YouTube, Spotify Web, SoundCloud, and Apple Music Web** in Chrome, Arc, Brave, Edge, or Safari.
- **Zero-Lag 60fps Karaoke Sweep** — Fetches word-by-word **NetEase YRC** lyrics (with cross-script Kanji/Romaji matching and cover/karaoke filtering) and falls back to **LRCLIB**, rendered via a local `TimelineView` with background AppleScript polling and a `-5.0s` to `+5.0s` **Timing Offset**.
- **Offline Japanese & Korean Romanization** — Built-in offline **Japanese → Romaji** (`CFStringTokenizer`) and **Korean → Romanized** (Revised Romanization) toggles for instant sing-along readability.
- **Customizable Visualizers & Album Art Themes** — Pick from 5 visualizer styles (**Bars, Wave, Dots, Vinyl, Note**), sync highlight or backdrop colors to album artwork, and fine-tune typography, font size, weight, and opacity in a clean 3-tab Settings window (`⌘,`).

## Install

### Homebrew (Recommended)

```bash
brew install --cask TrigrD3/tap/bartune
```

### Build from Source

Requires **macOS 13.0 (Ventura)+** and **Swift 5.9+** (Xcode or Xcode Command Line Tools).

```bash
git clone https://github.com/TrigrD3/bartune.git
cd bartune
chmod +x build.sh
./build.sh --install
open -a BarTune
```

## Settings (`⌘,`)

BarTune runs as a lightweight menu bar utility (`LSUIElement`) with a 3-tab native macOS Settings window:

| Tab | Options |
| :--- | :--- |
| **General** | Hover Behavior (*Cursor Spotlight* + width slider, or *Hide Entire Bar*), Browser Music toggle |
| **Appearance** | Color Theme (*System*, *Album Accent*, *Album Tint*), Background Opacity, Font Family, Weight, Size, Karaoke Sweep, Visualizer Style (*Bars / Wave / Dots / Vinyl / Note*) |
| **Lyrics & Sync** | Japanese → Romaji, Korean → Romanized, Karaoke Precision (*Low CPU* vs *High Precision*), Timing Offset stepper |

## Permissions

- **Automation (Spotify / Apple Music / Browsers):** On first launch, macOS prompts for Automation access so BarTune can read the current track and playback position. Manage this anytime under **System Settings → Privacy & Security → Automation**.
- **Browser Music (Optional):** To read playback from YouTube Music or web players, enable **Allow JavaScript from Apple Events** once in your browser:
  - **Chrome / Arc / Brave / Edge:** *View → Developer → Allow JavaScript from Apple Events*
  - **Safari:** *Safari → Settings → Advanced → Show features for web developers*, then *Develop → Allow JavaScript from Apple Events*

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup, Conventional Commits, and testing guidelines.

## License

MIT — see [LICENSE](LICENSE).
