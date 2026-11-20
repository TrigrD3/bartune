# Contributing to BarTune

Thank you for contributing to **BarTune**!

## Prerequisites

- **macOS 13.0+**
- **Swift 5.9+** (Xcode or Xcode Command Line Tools)
- Optional local lint tools: `brew install swiftlint swiftformat`

## Development Workflow

1. **Fork and branch** from `main`.
2. **Build & run tests** locally:
   ```bash
   swift build
   swift test
   ```
3. **Run lint & formatting checks** (matches CI):
   ```bash
   bash scripts/lint.sh
   ```
   To auto-format Swift files:
   ```bash
   swiftformat Sources Tests
   ```
4. **Verify `.app` bundle packaging**:
   ```bash
   ./build.sh
   ```

## Pull Requests

- Follow **Conventional Commits** (`<type>(<scope>): <description>`) for commit messages and PR titles — enforced in CI by `.github/workflows/pr-title.yml`.
- Enable the local `commit-msg` hook once per clone:
  ```bash
  git config core.hooksPath scripts/hooks
  ```
- Keep changes focused and add unit tests under `Tests/BarTuneTests/` for parser, timing, or model logic.
- Ensure `swift test`, `bash scripts/lint.sh`, and `./build.sh` pass before opening a PR.
- Docs-only PRs (`*.md`, `docs/**`) automatically skip macOS CI builds via `.github/filters.yml`.
