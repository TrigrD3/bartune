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
- For a bug fix, revert the fix and confirm the new test goes red, then passes with the fix restored.
- For something new (a type, a setting, a code path), a full revert is not that check: it also removes the new type, so its own tests fail even when nothing calls it. Replace the one line that carries the change into the running app (the argument that passes a new setting on, the condition that gates the new path) with a constant that still compiles, and confirm a test goes red; a build error does not count.
- Name that line and the test that went red in the PR template's **Tests** section, and fill in its "Not checked" line. A change with no behaviour to test (docs, CI, a pure refactor) writes "n/a" there.
- For a new feature, test the pure logic (parsers, romanizers, state/model helpers) at the cheapest layer first, using non-default inputs so a test cannot pass vacuously when a setting is ignored.
- Never pipe a test run into `tail`/`head`/`grep` without `set -o pipefail` — the shell exits with the last command's status and can mask a red suite.

### Hygiene

- No AI tool trailers (`Co-Authored-By:` for an assistant or session links) in commit messages; human co-authors are welcome.
- If you used AI tools, say so in the PR template's **AI assistance** section instead: which model wrote the change, and which ones you used to review or simplify it.
- No machine-local absolute paths or personal credentials in code, tests, or PR descriptions.

## Submitting a PR

1. Keep each PR focused on a single feature, bug fix, or refactor.
2. Rebase your branch onto `origin/main` before opening the PR.
3. Ensure `swift test`, `bash scripts/lint.sh`, and `./build.sh` all pass locally.
4. Use a Conventional Commit PR title (checked by `Conventional PR Title`).
5. Fill in every section of [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md): what changed and why with `Closes #<number>`, the Tests evidence, AI assistance (or delete it), and the checklist. This applies to PRs opened with `gh pr create --body` too: reproduce the template's headings.
6. Docs-only PRs (`*.md`, `docs/**`) automatically skip macOS CI builds via `.github/filters.yml`.

## Reporting Issues

Open a [GitHub Issue](https://github.com/TrigrD3/bartune/issues/new/choose) with the **Bug Report** or **Feature Request** form; blank issues are disabled.

- Title it `[Bug] <plain description>` or `[Feature] <plain description>`, e.g. `[Bug] LRC parser ignores the [offset:] header`. Conventional Commits are for PR titles and commits, not issue titles.
- Bug reports need the BarTune version, install method, macOS version, steps to reproduce, and a severity. The severity you pick sets the `severity: *` label automatically.
- Questions, setup help, and open-ended ideas go to [Discussions](https://github.com/TrigrD3/bartune/discussions).
- Maintainers add `area: *` labels (e.g. `area: parser`, `area: audio-sync`) and `privacy` / `performance` where relevant, and remove `needs-triage` once an issue is reviewed. `needs-verification` marks findings from code reading that still need a failing test or repro.

## Code Style

- All code, comments, and UI text in English.
- Keep solutions simple — avoid over-engineering and premature abstractions.
- Run `swiftformat Sources Tests` and `bash scripts/lint.sh` before committing Swift changes.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
