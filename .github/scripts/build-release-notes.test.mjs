import test from 'node:test';
import assert from 'node:assert/strict';
import {
  classifyEntry,
  extractMarkdownSection,
  extractReleaseSummary,
  humanizeTitle,
  isVersionBumpEntry,
  renderReleaseNotes,
} from './build-release-notes.mjs';

test('extractMarkdownSection extracts Summary and strips HTML comments', () => {
  const body = `## Summary

<!-- Plain-language overview -->

Reduces micro-stutters while Lyrics Alignment is syncing.

## What changed and why

Closes #210.
`;
  assert.equal(
    extractMarkdownSection(body, 'Summary'),
    'Reduces micro-stutters while Lyrics Alignment is syncing.',
  );
});

test('extractReleaseSummary falls back to What changed and why and skips Closes lines', () => {
  const body = `## Summary

<!-- empty -->

## What changed and why

Closes #42.

Adds caching for the compiled Core ML model across tracks.
`;
  assert.equal(
    extractReleaseSummary({ body }),
    'Adds caching for the compiled Core ML model across tracks.',
  );
});

test('extractReleaseSummary falls back to commit body when PR body is absent', () => {
  assert.equal(
    extractReleaseSummary({
      body: '',
      commitBody: 'Co-Authored-By: Someone\n\nCaches Core ML model across track switches.',
    }),
    'Caches Core ML model across track switches.',
  );
});

test('classifyEntry and humanizeTitle categorize Conventional Commits and labels', () => {
  assert.equal(classifyEntry('feat(app)!: remove whisper'), 'breaking');
  assert.equal(classifyEntry('perf(app): reduce sync stutter'), 'perf');
  assert.equal(classifyEntry('fix(app): guard retained track'), 'fix');
  assert.equal(classifyEntry('feat(app): add timeline'), 'feat');
  assert.equal(classifyEntry('chore: relicense under GPLv3'), 'other');
  assert.equal(humanizeTitle('perf(app): reduce sync stutter'), 'Reduce sync stutter');
  assert.equal(isVersionBumpEntry('chore(build): bump version to 0.8.0'), true);
  assert.equal(isVersionBumpEntry('perf(app): reduce sync stutter'), false);
});

test('renderReleaseNotes describes what is included in the release alongside merged PRs', () => {
  const notes = renderReleaseNotes({
    version: '0.8.0',
    tag: 'v0.8.0',
    previousTag: 'v0.7.0',
    repo: 'TrigrD3/bartune',
    entries: [
      {
        number: 211,
        title: 'perf(app): reduce audio-sync micro-stutters via model caching, background QoS, and capture batching',
        author: 'TrigrD3',
        labels: ['performance'],
        body: `## Summary

Reduces system-wide micro-stutters while Lyrics Alignment is actively syncing by caching the Core ML model across tracks.

## What changed and why

Closes #210.`,
      },
      {
        number: 212,
        title: 'chore(build): bump version to 0.8.0',
        author: 'TrigrD3',
        labels: [],
        body: '## Summary\n\nBumps VERSION to 0.8.0.',
      },
      {
        number: 213,
        title: 'chore(ci): internal tweak',
        author: 'TrigrD3',
        labels: ['ignore-for-release'],
        body: '## Summary\n\nShould be omitted from release notes.',
      },
    ],
  });

  assert.match(notes, /## What's Included in BarTune v0\.8\.0/);
  assert.match(notes, /### Performance/);
  assert.match(
    notes,
    /Reduce audio-sync micro-stutters via model caching, background QoS, and capture batching.*\[#211\].*Reduces system-wide micro-stutters while Lyrics Alignment is actively syncing/,
  );
  // Version bump PR should appear in Merged Pull Requests, not clutter What's Included highlights.
  assert.doesNotMatch(notes, /### Other Changes/);
  assert.doesNotMatch(notes, /#213/);
  assert.match(notes, /## Install or Upgrade/);
  assert.match(notes, /Download `BarTune-0\.8\.0\.dmg` and `BarTune-0\.8\.0\.dmg\.sha256` into the same directory/);
  assert.match(notes, /## Merged Pull Requests/);
  assert.match(notes, /- perf\(app\): reduce audio-sync micro-stutters.*by @TrigrD3 in #211/);
  assert.match(notes, /- chore\(build\): bump version to 0\.8\.0 by @TrigrD3 in #212/);
  assert.match(notes, /\*\*Full Changelog\*\*: https:\/\/github\.com\/TrigrD3\/bartune\/compare\/v0\.7\.0\.\.\.v0\.8\.0/);
});
