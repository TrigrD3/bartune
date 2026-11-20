# BarTune

## Project Structure

```
VERSION                    # App version (single source of truth, read by build.sh & release.yml)
Package.swift              # SwiftPM manifest (macOS 13+, BarTune executable + BarTuneTests)
Sources/BarTune/           # Native Swift macOS menu-bar app
  main.swift               # App entry point
  AppDelegate.swift        # Menu bar status item, Settings shortcut (⌘,), app lifecycle
  OverlayWindowController.swift # Left-of-notch overlay window (auxiliaryTopLeftArea) & hover/spotlight mask
  LyricsOverlayView.swift  # GPU-interpolated karaoke sweep, auto-scroll, animated equalizer
  LyricsState.swift        # Observable state & persisted user preferences
  SpotifyMonitor.swift     # Event-driven AppleScript playback monitor (Spotify & Apple Music)
  LyricsFetcher.swift      # NetEase YRC & LRCLIB lyrics fetching and caching
  Models.swift             # TrackInfo, LyricLine, WordTimestamp, LRC/YRC parsers
  AlbumArtColorExtractor.swift # Dominant/accent color extraction from album artwork
  Romanizer.swift          # Offline Japanese → Romaji conversion via CFStringTokenizer
  SettingsView.swift       # SwiftUI Settings window
Tests/BarTuneTests/        # XCTest unit tests (LRCParserTests, etc.)
scripts/
  lint.sh                  # Runs SwiftFormat (--lint) and SwiftLint (--strict)
build.sh                   # Release .app packager (--install for /Applications, --dmg for dist/*.dmg)
.github/
  filters.yml              # Shared dorny/paths-filter config (skips macOS jobs on docs-only PRs)
  workflows/ci.yml         # CI: changes -> lint + test + .app bundle verification (macos-26)
  workflows/release.yml    # Release: changes -> DMG + SHA256 build & GitHub Release on v* tags (macos-26)
```

## Pipeline

```
Spotify / Apple Music (AppleScript + distributed notifications)
  → SpotifyMonitor (track metadata, position, AppleScript latency compensation)
  → LyricsFetcher (NetEase YRC word-level sync → LRCLIB enhanced/standard LRC fallback)
  → Models (LRCParser / YRC) + Romanizer (CFStringTokenizer) + AlbumArtColorExtractor
  → LyricsState (observable state, timing offset, hover/theme/precision prefs)
  → OverlayWindowController + LyricsOverlayView (left-of-notch menu bar karaoke sweep)
```

## Key Commands

```bash
# Build & run tests
swift build
swift test

# Lint & format check (matches CI)
bash scripts/lint.sh

# Auto-format Swift sources & tests
swiftformat Sources Tests

# Build release BarTune.app
./build.sh

# Build and install to /Applications/BarTune.app
./build.sh --install

# Build release DMG + SHA-256 in dist/
./build.sh --dmg
```

## Critical Notes

- **Minimum OS & Swift**: `Package.swift` targets `.macOS(.v13)` with `swift-tools-version: 5.9`; `build.sh` sets `LSMinimumSystemVersion` to `13.0`. CI and release workflows run on `macos-26` (Apple Silicon).
- **Versioning**: Always bump `VERSION` rather than hardcoding version strings in `build.sh` or workflows. Tagging `vX.Y.Z` triggers `release.yml` to publish a GitHub Release with `BarTune-X.Y.Z.dmg` and its `.sha256`.
- **Linting**: CI runs `bash scripts/lint.sh --format-only` and `swiftlint lint --strict`. Run `bash scripts/lint.sh` locally before committing Swift changes.
- **Permissions**: BarTune is an `LSUIElement` menu-bar utility that requires macOS Automation (`NSAppleEventsUsageDescription`) access to query Spotify and Apple Music.
