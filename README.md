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

- **Tucked beside the notch.** BarTune occupies only the unused menu bar space to the left of your MacBook notch (`NSScreen.auxiliaryTopLeftArea`), so it never floats over your editor, browser, or terminal.
- **Steps aside on hover.** Pick **Cursor Spotlight** to peek only the menu item under your pointer, or **Hide Entire Bar** to reveal the full app menu bar on hover.
- **Works across desktop and web players.** Tracks **Spotify** and **Apple Music** natively, and falls back to **YouTube Music, YouTube (including Chapters), Spotify Web, SoundCloud, and Apple Music Web** in Chrome, Arc, Brave, Edge, or Safari.
- **Word-level karaoke sync and audio alignment.** Pulls millisecond **NetEase YRC** lyrics with **LRCLIB** fallback, and can optionally align lyrics to the playing audio using on-device **Apple Speech** (with automatic language detection) or **Local Whisper** (`whisper-cli`, reusing shared GGML models from `~/.cache/whisper` and `~/.cache/huggingface`). Synced timings are cached on disk so repeat plays load without recalculating, with a toggleable sync badge in the lyrics bar.
- **Translation and offline romanization.** Translate lyrics into your preferred language (cached locally) or turn on offline **Japanese → Romaji**, **Korean → Romanized**, and **Chinese → Pinyin** for sing-along readability.
- **Offline cache you can inspect.** Stores fetched lyrics, translations, audio-synced timings, and per-track timing offsets locally with a configurable cache limit and a searchable **Cached Songs** list in Settings.
- **Custom themes, visualizers, and live diagnostics.** Choose from 5 visualizer styles (**Bars, Wave, Dots, Vinyl, Note**), album-art accent or backdrop themes, custom typography, Launch at Login, macOS permission status indicators, and live/average CPU and memory metrics in a 5-tab Settings window (`⌘,`).

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

BarTune runs as a lightweight menu bar utility (`LSUIElement`) with a 5-tab native macOS Settings window:

| Tab | Options |
| :--- | :--- |
| **General** | Hover Behavior (*Cursor Spotlight* + width slider, or *Hide Entire Bar*), Browser Music toggle, Launch at Login, macOS Permission Status, Live & Average CPU/Memory Usage |
| **Appearance** | Color Theme (*System*, *Album Accent*, *Album Tint*), Background Opacity, Font Family, Weight, Size, Karaoke Sweep Highlight |
| **Visualizer** | Live Preview, Style (*Bars / Wave / Dots / Vinyl / Note*), Color Theme, Width, Animation toggle |
| **Lyrics & Sync** | Translation & Target Language, Romanization (*Japanese / Korean / Chinese*), Audio Karaoke Sync (*Off / Apple Speech / Local Whisper*, shared model picker, transcribed-audio overwrite, lyrics-bar sync badge), Karaoke Precision (*Low CPU* vs *High Precision 30fps*), Per-Track Timing Offset |
| **Offline Cache** | Cached song & audio-synced counts, storage usage, cache limit, searchable **Cached Songs** list, Reveal in Finder, Clear Cache |

## Permissions

- **Automation (Spotify / Apple Music / Browsers):** On first launch, macOS prompts for Automation access so BarTune can read the current track and playback position. Manage this anytime under **System Settings → Privacy & Security → Automation**.
- **Screen & System Audio Recording & Speech Recognition (Optional):** Only needed if you enable **Audio Karaoke Sync** (*Apple Speech* or *Local Whisper*). BarTune captures system playback audio only — never your microphone.
- **Browser Music (Optional):** To read playback from YouTube Music or web players, enable **Allow JavaScript from Apple Events** once in your browser:
  - **Chrome / Arc / Brave / Edge:** *View → Developer → Allow JavaScript from Apple Events*
  - **Safari:** *Safari → Settings → Advanced → Show features for web developers*, then *Develop → Allow JavaScript from Apple Events*

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup, Conventional Commits, and testing guidelines.

## License

MIT — see [LICENSE](LICENSE).
