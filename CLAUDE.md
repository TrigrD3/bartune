# BarTune

## Project Structure

```
VERSION                    # App version (single source of truth, read by build.sh & release.yml)
Package.swift              # SwiftPM manifest (macOS 13+, BarTune executable + BarTuneTests)
Sources/BarTune/           # Native Swift macOS menu-bar app
  main.swift               # App entry point
  AppDelegate.swift        # Menu bar status item, Settings shortcut (⌘,), app lifecycle
  OverlayWindowController.swift # Left-of-notch overlay window (auxiliaryTopLeftArea) & hover/spotlight mask
  LyricsOverlayView.swift  # GPU-interpolated karaoke sweep, word pop, typing caret, line transitions, auto-scroll, animated equalizer
  LyricsState.swift        # Observable state & persisted user preferences
  SpotifyMonitor.swift     # Event-driven AppleScript playback monitor (Spotify, Apple Music, browser fallback)
  BrowserMediaMonitor.swift # Browser tab music monitor (YouTube Music, YouTube, Spotify Web, SoundCloud, Apple Music Web)
  LyricsFetcher.swift      # NetEase YRC & LRCLIB lyrics fetching and caching
  CustomLyricsStore.swift  # Application Support persistence for user-timed Custom lyrics & per-song source resolution
  LyricTimingSession.swift # Pure tap-stamping, word-splitting, nudging & duration-derivation model for the timing editor
  LyricTimingEditorView.swift # Manual Lyric Timing Editor window (tap-to-time lines/words, fine-tune, per-song source picker)
  LyricsForcedAligner.swift # Lyrics Alignment engine: CTC Viterbi of romanized lyrics over a Core ML acoustic model (Neural Engine)
  AudioSyncDiagnostics.swift # Live audio sync diagnostics (Settings → Advanced Diagnostics, unified log `audio-sync`)
  VocalWaveform.swift      # Voice-band vocal envelope (stereo centre-weighted) & Lyrics Alignment word timing refiner: held-note extension, silence gating
  Models.swift             # TrackInfo, LyricLine, WordTimestamp, LRC/YRC parsers
  AlbumArtColorExtractor.swift # Dominant/accent color extraction from album artwork
  Romanizer.swift          # Offline Japanese → Romaji conversion via CFStringTokenizer
  SettingsView.swift       # SwiftUI Settings window
  AppUpdater.swift         # GitHub Releases update check & SHA-256-verified DMG download (About tab)
  AppInstaller.swift       # Install & Relaunch: mounts the verified DMG, swaps BarTune.app in place (not for Homebrew installs)
Tests/BarTuneTests/        # XCTest unit tests (LRCParserTests, BrowserMediaParserTests, etc.)
docs/research/             # Primary-source research notes (e.g. lyrics-alignment-coverage.md for Lyrics Alignment work)
Casks/
  bartune.rb               # Homebrew Cask template synced to TrigrD3/homebrew-tap on v* tags
scripts/
  lint.sh                  # Runs SwiftFormat (--lint) and SwiftLint (--strict)
  convert-lyrics-aligner.py # Builds LyricsAligner.mlpackage (MMS forced-aligner → Core ML, 8-bit) for the Lyrics Alignment engine
  export-coverage.sh       # CI LCOV export; fails when the test binary, profdata, or report is missing
  fetch-jamendolyrics.sh   # Downloads JamendoLyrics (word-annotated, Creative Commons audio; never commit it) for AlignmentEvalTests
  playback-clock-report.py # Per-track summary of the `playback-clock` debug log (overlay clock vs player position per poll)
  hooks/commit-msg         # Local Conventional Commits git hook
build.sh                   # Release .app packager (--install for /Applications, --dmg for dist/*.dmg)
.github/
  PULL_REQUEST_TEMPLATE.md # PR body sections every PR fills in (see Git Workflow)
  filters.yml              # Shared dorny/paths-filter config (skips macOS jobs on docs-only PRs)
  dependabot.yml           # Weekly dependency updates for github-actions & swift
  workflows/ci.yml         # CI: changes -> lint + test + codecov + .app bundle verification (macos-26)
  workflows/release.yml    # Release: changes -> read-only DMG build; v* tags publish GitHub Release + Homebrew tap, pushes to main refresh the "Latest (main)" pre-release
  workflows/codeql.yml     # CodeQL security analysis for Swift & GitHub Actions
  workflows/pr-title.yml   # Enforces Conventional Commits on PR titles
  workflows/dependabot-auto-merge.yml # Enables auto-merge for Dependabot patch/minor PRs
  workflows/issue-severity-labeler.yml # Auto-labels issue severity from template dropdown or keyword fallback
  scripts/classify-issue-severity.mjs # Pure issue severity classifier (tested with node --test)
  scripts/ci-workflows.test.mjs # Workflow permission & coverage-export checks (node --test, not run in CI)
.codecov.yml               # Soft-gated Codecov coverage reporting config
```

## Pipeline

```
Spotify / Apple Music (AppleScript + distributed notifications)
  ↳ Fallback when idle: BrowserMediaMonitor (Chrome, Arc, Brave, Edge, Safari — Web Media Session + <video>/<audio>)
  → SpotifyMonitor (track metadata, position, AppleScript latency compensation, interpolation timer)
  → LyricsFetcher (NetEase YRC word-level sync → LRCLIB enhanced/standard LRC fallback)
  → Models (LRCParser / YRC) + Romanizer (CFStringTokenizer) + AlbumArtColorExtractor
  ↳ Audio sync (optional): ScreenCaptureKit stereo capture → Lyrics Alignment words → VocalWaveform refinement → LyricsAudioAligner
  → LyricsState (observable state, timing offset, hover/theme/precision/browser prefs)
  → OverlayWindowController + LyricsOverlayView (left-of-notch menu bar karaoke sweep)
```

## Setup

```bash
# Build, package, and install to /Applications/BarTune.app
chmod +x build.sh
./build.sh --install
open -a BarTune

# Enable local Conventional Commits hook once per clone
git config core.hooksPath scripts/hooks
```

## Key Commands

```bash
# Build & run tests
# Never pipe a test run into `tail`/`head`/`grep` to shorten it: the shell reports
# the *last* command's status, so `... | tail -60` exits 0 on a red suite.
# Redirect to a file (`> /tmp/run.log 2>&1`) or enable `set -o pipefail` instead.
swift build
swift test

# Score audio sync against annotated songs (opt-in, skipped without the env var; needs the
# Lyrics Alignment model installed). Run it on main and on a branch to compare an audio sync change.
scripts/fetch-jamendolyrics.sh <dir> English
BARTUNE_EVAL_DIR=<dir> swift test --filter AlignmentEvalTests > <log> 2>&1

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

- `VERSION` is the single source of truth for the stable release version (read by `build.sh` and `release.yml`); only `BARTUNE_RELEASE=1` builds (stable `v*` releases) report it. Every other build follows the newest `vX.Y.Z` tag: `X.Y.(Z + commits since that tag)`, e.g. `v0.4.0` + 15 commits = `0.4.15`, restarting at `0.5.0` once `v0.5.0` is tagged. Because PATCH numbers belong to builds from main, stable releases bump MINOR or MAJOR (`X.Y.0`); a stable patch release would make later main builds sort below builds already shipped. `build.sh` also stamps `CFBundleVersion` (total commit count), `BarTuneGitCommit` (short hash) and `BarTuneReleaseChannel` (`stable`/`dev`); never hand-edit those Info.plist values.
- Stable releases are on-demand only via `.github/workflows/release.yml`: either push a `vX.Y.Z` tag (matching `VERSION`, or the job fails) or run **Build & Release DMG** via `workflow_dispatch` with `publish: true`. This builds `BarTune-X.Y.Z.dmg` + `.sha256`, creates the GitHub Release, and updates `Casks/bartune.rb` in `TrigrD3/homebrew-tap` (using `HOMEBREW_TAP_TOKEN`; without that secret the tap step is skipped, so `brew upgrade` won't see the release). A tag with a nonzero PATCH fails the job (see the rule above).
- Pushes to `main` build `BarTune-X.Y.Z.dmg` (version per the rule above) and replace the assets of the rolling `dev` pre-release ("Latest (main)"), moving the `dev` tag to that commit. A queued run superseded by a newer push may be skipped, and a rerun of a commit older than the current `dev` tag publishes nothing. Being a pre-release, it never becomes `/releases/latest` and never reaches Homebrew; the in-app updater reads it only on the *Latest from main* channel.
- PRs targeting `main` run the DMG build as a CI check. Only the `publish-stable` and `publish-main` jobs get `contents: write`; the `build` job that runs PR code stays read-only.
- Users install via `brew install --cask TrigrD3/tap/bartune`.

## Git Workflow

- **Branch protection:** `main` is protected — never push directly to `main`. Always open a pull request and merge after required checks (`lint`, `test`, `Conventional PR Title`) pass.
- **Issue tracking:** before starting work on a new feature, create a GitHub issue for it and link the pull request to that issue (e.g., `Closes #<number>`).
- **Issue format:** follow the forms in `.github/ISSUE_TEMPLATE/` (blank issues are disabled; questions go to Discussions). Titles are `[Bug] <plain description>` or `[Feature] <plain description>`; Conventional Commits apply to PR titles and commits, not issues. When filing with `gh issue create`, reproduce the form's `### <Label>` headings so `issue-severity-labeler.yml` can read `### Severity`.
- **Issue labels:** one type (`bug`, `enhancement`, `documentation`), one `severity: *` for bugs, one or more `area: *` (audio-sync, aligner, playback-monitor, lyrics-fetch, parser, translation, overlay, settings, build, ci), plus `privacy`, `performance`, `needs-verification` (found by code reading, unconfirmed) or `needs-triage` (set by the forms; remove once reviewed) where they apply.
- **Conventional Commits:** `<type>(<scope>): <description>` — types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `build`, `ci`, `revert`. Enforced in CI (`pr-title.yml`) and locally (`scripts/hooks/commit-msg`).
- **Scopes:** `app`, `test`, `build`, `ci`, `docs`, `deps`.
- **Atomic commits:** one logical change per commit. Fold review fixes into the commit they belong to (`git commit --fixup` + `git rebase --autosquash`).
- **Stage explicitly:** `git add <file1> <file2>` — avoid blanket `git add -A` on dirty trees.
- **Verify first:** run `swift test`, `bash scripts/lint.sh`, and `./build.sh` before committing Swift changes.
- **PR body:** follow `.github/PULL_REQUEST_TEMPLATE.md` for every PR, including ones opened with `gh pr create --body`: keep its headings (What changed and why, Tests, AI assistance, Checklist) and fill them per `CONTRIBUTING.md` → Tests.
- **Commit body:** document the *why* for non-trivial changes (architecture decisions, rejected alternatives).
- **Hygiene:** no AI tool trailers (`Co-Authored-By:` for assistants, session links) in commit messages; no local machine paths in code, tests, or PR text.
- **Contributor workflow:** before committing, read `CONTRIBUTING.md` if you haven't this session.

## Conventions

- All code, comments, and UI text in English.
- Keep implementations simple — avoid over-engineering and premature abstractions.
- Preserve existing comments and docstrings unrelated to your changes.

## Maintaining This File

- **Placement:** a line belongs here only if an agent working in any area needs it without being told to look.
- **Content:** state the current rule and why it holds. Incident stories belong in issues and commit messages.
- **Upkeep:** a change that alters documented behaviour updates this file in the same commit, rewriting or removing stale text in place. Keep each fact in one place and point to it from anywhere else (`AGENTS.md` is symlinked to `CLAUDE.md`).

## Cross-Cutting Rules

- Test each behaviour at the cheapest layer that can falsify it: pure parser/model/romanizer unit tests in `Tests/BarTuneTests/` first before manual UI verification.
- A new test must fail without the production change it verifies; use non-default inputs when verifying settings.
- **Destructive UI confirmation:** Any destructive or irreversible UI action (clearing caches, deleting saved files/entries, resetting multi-field configurations) must present a confirmation dialog (`.alert` / `.confirmationDialog`) explaining what will be removed before mutating state or disk.

## Critical Notes

- **Minimum OS & Swift:** `Package.swift` targets `.macOS(.v13)` with `swift-tools-version: 5.9`; `build.sh` sets `LSMinimumSystemVersion` to `13.0`. CI and release workflows run on `macos-26` (Apple Silicon).
- **Linting:** CI runs `bash scripts/lint.sh --format-only` and `swiftlint lint --strict`. Run `bash scripts/lint.sh` locally before committing Swift changes.
- **Permissions:** BarTune is an `LSUIElement` menu-bar utility that requires macOS Automation (`NSAppleEventsUsageDescription`) access to query Spotify, Apple Music, and supported browsers (browsers also need *Allow JavaScript from Apple Events* enabled).
- **Signing keeps permissions:** macOS ties Screen & System Audio Recording and Speech grants to the signing certificate (ad hoc: to the exact binary). `build.sh` re-signs with the certificate `/Applications/BarTune.app` already carries, else Developer ID, else Apple Development; CI DMGs (and the in-app updater's main-channel builds) are ad-hoc, so installing one over a locally signed app, or the reverse, asks for those permissions again.
- **Locale-safe AppleScript parsing:** Playback position parsing must handle comma-decimal locales (`en_ID`, `de_DE`, `uk_UA`, etc.).
- **Dependabot Auto-Merge:** `.github/workflows/dependabot-auto-merge.yml` enables GitHub auto-merge (`--rebase`) for patch and minor Dependabot PRs once required status checks pass.
