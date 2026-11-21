import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseDropdownSeverity,
  inferKeywordSeverity,
  resolveIssueSeverity,
} from './classify-issue-severity.mjs';

test('parseDropdownSeverity parses all four dropdown options', () => {
  assert.equal(
    parseDropdownSeverity('### Severity\n\nCritical — Crash, data loss'),
    'critical',
  );
  assert.equal(
    parseDropdownSeverity('### Severity\r\n\r\nHigh — Major feature broken'),
    'high',
  );
  assert.equal(
    parseDropdownSeverity('### Severity\n\nMedium — Noticeable issue'),
    'medium',
  );
  assert.equal(
    parseDropdownSeverity('### Severity\n\nLow — Minor glitch'),
    'low',
  );
});

test('parseDropdownSeverity returns null for missing or _No response_', () => {
  assert.equal(parseDropdownSeverity(''), null);
  assert.equal(parseDropdownSeverity('### Severity\n\n_No response_'), null);
  assert.equal(parseDropdownSeverity('### What happened?\n\nApp crashed'), null);
});

test('dropdown selection overrides conflicting keywords and removes stale severity labels', () => {
  const result = resolveIssueSeverity({
    title: 'App crashes on launch',
    body: '### Severity\n\nLow — Minor glitch, cosmetic issue, or edge case',
    labels: ['bug', 'severity: critical'],
  });

  assert.equal(result.targetLabel, 'severity: low');
  assert.equal(result.source, 'dropdown');
  assert.equal(result.shouldAdd, true);
  assert.deepEqual(result.labelsToRemove, ['severity: critical']);
  assert.equal(result.changed, true);
});

test('dropdown selection is a no-op when matching label is already present', () => {
  const result = resolveIssueSeverity({
    title: 'Lyrics misaligned',
    body: '### Severity\n\nMedium — Noticeable issue with a workaround',
    labels: ['bug', 'severity: medium'],
  });

  assert.equal(result.targetLabel, 'severity: medium');
  assert.equal(result.shouldAdd, false);
  assert.deepEqual(result.labelsToRemove, []);
  assert.equal(result.changed, false);
});

test('inferKeywordSeverity classifies critical, high, medium, and low issues', () => {
  assert.equal(
    inferKeywordSeverity('CPU sampler leaks Mach thread send rights', ''),
    'critical',
  );
  assert.equal(
    inferKeywordSeverity('App crashes when switching tracks', ''),
    'critical',
  );
  assert.equal(
    inferKeywordSeverity('Release build is arm64-only while the cask targets Intel', ''),
    'high',
  );
  assert.equal(
    inferKeywordSeverity('YRC word regex truncates lyric text', ''),
    'high',
  );
  assert.equal(
    inferKeywordSeverity('Overlay flickers intermittently when hovering', ''),
    'medium',
  );
  assert.equal(
    inferKeywordSeverity('Small typo in Settings tooltip', ''),
    'low',
  );
  assert.equal(
    inferKeywordSeverity('In-memory caches grow without bound', ''),
    'critical',
  );
  assert.equal(
    inferKeywordSeverity('Active translation keeps stale timestamps after audio alignment', ''),
    null,
  );
  assert.equal(
    inferKeywordSeverity('Unexpected behavior in menu bar', ''),
    'medium',
  );
});

test('preserves existing manual severity label when no dropdown is selected', () => {
  const result = resolveIssueSeverity({
    title: 'App crashes immediately',
    body: '### Severity\n\n_No response_\n\n### What happened?\n\nCrash',
    labels: ['bug', 'severity: low'],
  });

  assert.equal(result.source, 'existing');
  assert.equal(result.changed, false);
  assert.equal(result.shouldAdd, false);
  assert.deepEqual(result.labelsToRemove, []);
});

test('skips enhancement, documentation, and question issues without bug label', () => {
  for (const label of ['enhancement', 'documentation', 'question']) {
    const result = resolveIssueSeverity({
      title: 'Add crash reporting support',
      body: 'Would be great to handle crashes gracefully',
      labels: [label],
    });
    assert.equal(result.source, 'skipped');
    assert.equal(result.changed, false);
  }
});

test('defaults to severity: medium for bug issues with no matching keywords', () => {
  const result = resolveIssueSeverity({
    title: 'Track title behaves strangely in menu bar',
    body: 'Noticed something odd while playing music.',
    labels: ['bug'],
  });

  assert.equal(result.targetLabel, 'severity: medium');
  assert.equal(result.source, 'default-bug');
  assert.equal(result.shouldAdd, true);
  assert.equal(result.changed, true);
});

test('defaults to severity: low for unlabeled issues with no matching keywords', () => {
  const result = resolveIssueSeverity({
    title: 'General note about menu bar',
    body: 'Just sharing an observation.',
    labels: [],
  });

  assert.equal(result.targetLabel, 'severity: low');
  assert.equal(result.source, 'default');
  assert.equal(result.shouldAdd, true);
  assert.equal(result.changed, true);
});
