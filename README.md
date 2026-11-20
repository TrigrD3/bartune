# BarTune

A lightweight native macOS app that displays real-time karaoke lyrics in the menu bar **to the left of the MacBook notch** — never overlapping your browser tabs or windows.

Supports **Spotify** and **Apple Music** out of the box with no login or API keys.

## Features

- **Left-of-Notch Menu Bar Placement** — Uses `NSScreen.auxiliaryTopLeftArea` on notched MacBooks so lyrics sit strictly inside the menu bar height.
- **Hover-to-Reveal App Menus** — Switch in Settings between **Cursor Spotlight** (peeks only the menu item under your pointer) and **Hide Entire Bar** (fades out the full strip on hover).
- **Karaoke Sweep Animation** — Smooth 30fps left-to-right highlight with auto-scrolling for long lines and an animated equalizer.
- **Album Art Color Themes** — Syncs highlight or backdrop colors to the current Spotify album artwork.
- **Custom Typography** — Choose from 8 font families, 4 weights, and custom font size in Settings (`⌘,`).
- **Japanese → Romaji** — Built-in offline macOS `CFStringTokenizer` converts Japanese lyrics (Kanji, Hiragana, Katakana) to readable Romaji automatically.
- **Spotify + Apple Music** — Reads local playback via AppleScript with comma-decimal locale support (`en_ID`, `de_DE`, `uk_UA`, etc.).

## Build & Install

```bash
chmod +x build.sh
./build.sh --install
open -a BarTune
```
