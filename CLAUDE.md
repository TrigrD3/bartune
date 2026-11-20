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
  workflows/ci.yml         # CI: changes -> lint + test + codecov + .app bundle verification (macos-26)
  workflows/release.yml    # Release: changes -> DMG + SHA256 build & GitHub Release on v* tags (macos-26)
  workflows/codeql.yml     # CodeQL security analysis for Swift & GitHub Actions
.codecov.yml               # Soft-gated Codecov coverage reporting config
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

## Setup

```bash
# Build, package, and install to /Applications/BarTune.app
chmod +x build.sh
./build.sh --install
open -a BarTune
```

## Key Commands

```bash
# Build & run tests
# Never pipe a test run into `tail`/`head`/`grep` to shorten it: the shell reports
# the *last* command's status, so `... | tail -60` exits 0 on a red suite.
# Redirect to a file (`> /tmp/run.log 2>&1`) or enable `set -o pipefail` instead.
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

## Distribution

- `VERSION` is the single source of truth for app versioning (`build.sh` and `release.yml` both read it).
- Tagging `vX.Y.Z` triggers `.github/workflows/release.yml` to build `BarTune-X.Y.Z.dmg` + `.sha256` and publish a GitHub Release automatically.

## Git Workflow

- **Conventional Commits:** `<type>(<scope>): <description>` — types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `build`, `ci`, `revert`.
- **Scopes:** `app`, `test`, `build`, `ci`, `docs`.
- **Atomic commits:** one logical change per commit.
- **Stage explicitly:** `git add <file1> <file2>` — avoid blanket `git add -A` on dirty trees.
- **Verify first:** run `swift test` and `bash scripts/lint.sh` before committing Swift changes.
- **Commit body:** document the *why* for non-trivial changes (architecture decisions, rejected alternatives).
- **Contributor workflow:** before committing, read `CONTRIBUTING.md` if you haven't this session.

## Conventions

- All code, comments, and UI text in English.
- Preserve existing comments and docstrings unrelated to your changes.

## Maintaining This File

- **Placement:** a line belongs here only if an agent working in any area needs it without being told to look.
- **Content:** state the current rule and why it holds. Incident stories belong in issues and commit messages.
- **Upkeep:** a change that alters documented behaviour updates this file in the same commit, rewriting or removing stale text in place. Keep each fact in one place and point to it from anywhere else (`AGENTS.md` is symlinked to `CLAUDE.md`).

## Cross-Cutting Rules

- Test each behaviour at the cheapest layer that can falsify it: pure parser/model/romanizer unit tests in `Tests/BarTuneTests/` first before manual UI verification.
- A new test must fail without the production change it verifies.

## Critical Notes

- **Minimum OS & Swift:** `Package.swift` targets `.macOS(.v13)` with `swift-tools-version: 5.9`; `build.sh` sets `LSMinimumSystemVersion` to `13.0`. CI and release workflows run on `macos-26` (Apple Silicon).
- **Linting:** CI runs `bash scripts/lint.sh --format-only` and `swiftlint lint --strict`. Run `bash scripts/lint.sh` locally before committing Swift changes.
- **Permissions:** BarTune is an `LSUIElement` menu-bar utility that requires macOS Automation (`NSAppleEventsUsageDescription`) access to query Spotify and Apple Music.
- **Locale-safe AppleScript parsing:** Playback position parsing must handle comma-decimal locales (`en_ID`, `de_DE`, `uk_UA`, etc.).
