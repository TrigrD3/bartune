# Contributing to BarTune

Thank you for contributing to **BarTune**!

## Prerequisites

- **macOS 13.0 (Ventura)+** to run the app
- **Swift 5.9+** (Xcode or Xcode Command Line Tools) to build from source (`Package.swift` declares `swift-tools-version: 5.9`)
- For local linting (`bash scripts/lint.sh`), install SwiftLint and SwiftFormat:
  ```bash
  brew install swiftlint swiftformat
  ```

## Setup

```bash
git clone https://github.com/TrigrD3/bartune.git
cd bartune
./build.sh --install
open -a BarTune
```

Run the test suite and linter to verify everything works:

```bash
swift test
bash scripts/lint.sh
```

Enable the repository's local Conventional Commits hook once per clone:

```bash
git config core.hooksPath scripts/hooks
```

## Development Workflow

### Branching

`main` is protected — all changes land via pull request. Create a feature branch from `main`:

```bash
git checkout -b feat/my-feature main
```

**Prefer rebasing over merging `main` into your branch:**

```bash
git fetch origin
git rebase origin/main
```

### Commit Conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/). See [`CLAUDE.md`](CLAUDE.md) for the types, scopes, and rules enforced by `.github/workflows/pr-title.yml` and `scripts/hooks/commit-msg`.

Examples:

```text
feat(app): add browser music playback support
fix(app): handle comma-decimal locales in AppleScript position parsing
test(test): add BrowserMediaParser URL and payload tests
ci(ci): allow deps scope in Conventional PR Title check
```

**Fold review changes into the commit they belong to** so history stays atomic (one logical change per commit):

- While review is ongoing, you can push `fixup!` commits:
  ```bash
  git commit --fixup=<sha>
  ```
- Once review has settled, fold fixups before merge:
  ```bash
  git fetch origin
  git rebase --autosquash origin/main
  git push --force-with-lease
  ```

### AI-Assisted Development

This repository includes [`CLAUDE.md`](CLAUDE.md) (with [`AGENTS.md`](AGENTS.md) symlinked to it) documenting project structure, data pipeline, commands, and cross-cutting rules.

### Tests

All new features and bug fixes that change runtime behaviour must include unit tests under `Tests/BarTuneTests/`. Run the full suite before opening a PR:

```bash
swift test
```

A test counts when it fails without your change:
- For a bug fix, verify the new test fails before the fix and passes after.
- For a new feature, test the pure logic (parsers, romanizers, state/model helpers) at the cheapest layer first, using non-default inputs so a test cannot pass vacuously when a setting is ignored.
- Never pipe a test run into `tail`/`head`/`grep` without `set -o pipefail` — the shell exits with the last command's status and can mask a red suite.

### Hygiene

- No AI tool trailers (`Co-Authored-By:` for an assistant or session links) in commit messages; human co-authors are welcome.
- If you used AI tools, mention it in the PR description if helpful for reviewers.
- No machine-local absolute paths or personal credentials in code, tests, or PR descriptions.

## Submitting a PR

1. Keep each PR focused on a single feature, bug fix, or refactor.
2. Rebase your branch onto `origin/main` before opening the PR.
3. Ensure `swift test`, `bash scripts/lint.sh`, and `./build.sh` all pass locally.
4. Use a Conventional Commit PR title (checked by `Conventional PR Title`).
5. Explain **what** changed and **why** in the PR description, and link any related issues.
6. Docs-only PRs (`*.md`, `docs/**`) automatically skip macOS CI builds via `.github/filters.yml`.

## Reporting Issues

Use [GitHub Issues](https://github.com/TrigrD3/bartune/issues) with the Bug Report or Feature Request template.

## Code Style

- All code, comments, and UI text in English.
- Keep solutions simple — avoid over-engineering and premature abstractions.
- Run `swiftformat Sources Tests` and `bash scripts/lint.sh` before committing Swift changes.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
