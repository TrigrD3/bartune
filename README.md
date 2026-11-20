# LeftBar Lyrics

A lightweight native macOS app that displays real-time synced Spotify lyrics in the menu bar **to the left of the MacBook notch** — never overlapping your browser tabs or windows.

Hover your mouse over the left menu bar area and the lyrics instantly fade away to reveal your normal `File, Edit, View, Window, Help` menus. Move your cursor away and the lyrics smoothly return.

## Features

- **Left-of-Notch Menu Bar Placement** — Uses `NSScreen.auxiliaryTopLeftArea` on notched MacBooks so lyrics sit strictly inside the menu bar height (never covering tabs).
- **Hover-to-Reveal App Menus** — Moving your mouse into the left menu bar instantly hides the lyrics and passes clicks straight through to `File, Edit, View, Window, Help`.
- **Locale-Safe Spotify Sync** — Reads playback directly from Spotify Desktop via AppleScript with comma-decimal support (`en_ID`, `de_DE`, `uk_UA`, etc.).
- **No Login or API Keys** — Fetches time-synced LRC lyrics from [LRCLIB](https://lrclib.net).
- **Auto-Hide When Paused** — Automatically reveals your normal menu bar whenever Spotify is paused or closed.
- **Sync Offset Controls** — Click the `♫` icon on the right side of the menu bar to toggle lyrics or nudge timing (`±0.5s`).

## Build & Install

```bash
chmod +x build.sh
./build.sh --install
open -a LeftBarLyrics
```

On first launch, allow macOS **Automation** permission so LeftBar Lyrics can read the currently playing song from Spotify.
