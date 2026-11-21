## What changed and why

<!-- One or two lines. Link the issue: "Closes #<number>". -->

## Tests

<!-- A fix to existing code: revert it and name the test that went red. Something new
(type, setting, code path): replace the one line that wires it into the app with a
constant instead, since a full revert also removes the new type's own tests.
No behaviour to test (docs, CI, pure refactor): write "n/a". See CONTRIBUTING.md, Tests. -->

- Reverted, or line set to a constant: <!-- file:line -->
- Test that went red: <!-- test name -->
- Not checked: <!-- inputs, players, browsers or locales you did not try; "nothing" is a fine answer -->

## AI assistance

<!-- Delete this section if you used none. Models go here, not in commit trailers. -->

- Written with: <!-- e.g. the model and tool that wrote most of the change -->
- Reviewed or simplified with: <!-- models used for review passes, if any -->

## Checklist

- [ ] Rebased on `main`, no merge commits, since a merge commit pulls commits that are
      already on `main` into this branch and the review reads it commit by commit:
      `git fetch https://github.com/TrigrD3/bartune main && git rebase FETCH_HEAD`
      (the URL spelled out because in a fork clone `origin` is your fork)
- [ ] `bash scripts/lint.sh` is clean (CI runs SwiftFormat `--lint` and SwiftLint `--strict`)
- [ ] Tests pass: `swift test`
- [ ] `./build.sh` packages `BarTune.app` cleanly
- [ ] Conventional Commits, one logical change per commit

The **Update branch** button merges by default; pick **Update with rebase** from its
dropdown instead. Would rather not rewrite history? Leave *Allow edits by maintainers*
checked and a maintainer folds the commits before merging, as
[CONTRIBUTING.md](https://github.com/TrigrD3/bartune/blob/main/CONTRIBUTING.md)
offers.
