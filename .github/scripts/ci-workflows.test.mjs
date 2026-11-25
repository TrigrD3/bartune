import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../..');
const exportScript = path.join(repoRoot, 'scripts/export-coverage.sh');

function readWorkflow(name) {
  return fs.readFileSync(path.join(repoRoot, '.github/workflows', name), 'utf8');
}

function extractJobBlock(yamlText, jobName) {
  const lines = yamlText.split('\n');
  const startIdx = lines.findIndex((line) => line === `  ${jobName}:`);
  assert.notEqual(startIdx, -1, `Expected job '${jobName}' to exist`);
  const collected = [lines[startIdx]];
  for (let i = startIdx + 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (/^  [a-zA-Z0-9_-]+:\s*$/.test(line)) {
      break;
    }
    collected.push(line);
  }
  return collected.join('\n');
}

test('ci.yml and release.yml grant pull-requests: read and contents: read to changes jobs (#125)', () => {
  for (const workflow of ['ci.yml', 'release.yml']) {
    const content = readWorkflow(workflow);
    const changesJob = extractJobBlock(content, 'changes');
    assert.match(
      changesJob,
      /^\s{4}permissions:\s*$/m,
      `${workflow} changes job must declare explicit permissions`,
    );
    assert.match(
      changesJob,
      /^\s{6}contents:\s*read\s*$/m,
      `${workflow} changes job must grant contents: read`,
    );
    assert.match(
      changesJob,
      /^\s{6}pull-requests:\s*read\s*$/m,
      `${workflow} changes job must grant pull-requests: read for dorny/paths-filter`,
    );
  }
});

test('ci.yml invokes scripts/export-coverage.sh and does not silently skip Codecov upload (#124)', () => {
  const ci = readWorkflow('ci.yml');
  const testJob = extractJobBlock(ci, 'test');
  assert.match(
    testJob,
    /scripts\/export-coverage\.sh/,
    'ci.yml test job must invoke scripts/export-coverage.sh',
  );
  assert.doesNotMatch(
    testJob,
    /hashFiles\('coverage\.lcov'\)/,
    'ci.yml must not silently skip Codecov upload when coverage.lcov is missing',
  );
});

function createMockBinDir(dir, llvmCovScript) {
  const mockBin = path.join(dir, 'mock-bin');
  fs.mkdirSync(mockBin, { recursive: true });
  const xcrunPath = path.join(mockBin, 'xcrun');
  fs.writeFileSync(
    xcrunPath,
    `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "llvm-cov" ]]; then
  shift
${llvmCovScript}
fi
echo "unexpected xcrun invocation: $*" >&2
exit 2
`,
    { mode: 0o755 },
  );
  return mockBin;
}

test('export-coverage.sh exports LCOV from BarTuneTests.xctest nested bundle (#124)', () => {
  assert.equal(fs.existsSync(exportScript), true, 'scripts/export-coverage.sh must exist');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bartune-cov-bundle-'));
  try {
    const binDir = path.join(tmp, 'Products/Debug');
    const testBin = path.join(binDir, 'BarTuneTests.xctest/Contents/MacOS/BarTuneTests');
    const codecovDir = path.join(binDir, 'codecov');
    const profdata = path.join(codecovDir, 'default.profdata');
    const output = path.join(tmp, 'coverage.lcov');

    fs.mkdirSync(path.dirname(testBin), { recursive: true });
    fs.writeFileSync(testBin, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    fs.mkdirSync(codecovDir, { recursive: true });
    fs.writeFileSync(profdata, 'mock-profdata');

    const mockBin = createMockBinDir(
      tmp,
      `  echo "SF:Sources/BarTune/Models.swift"
  echo "LF:10"
  echo "LH:8"
  echo "end_of_record"
  exit 0`,
    );

    execFileSync('bash', [exportScript, '--bin-path', binDir, '--profdata', profdata, '--output', output], {
      env: { ...process.env, PATH: `${mockBin}:${process.env.PATH}` },
      encoding: 'utf8',
    });

    assert.equal(fs.existsSync(output), true);
    const lcov = fs.readFileSync(output, 'utf8');
    assert.match(lcov, /SF:Sources\/BarTune\/Models\.swift/);
    assert.ok(lcov.trim().length > 0, 'coverage.lcov must be non-empty');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('export-coverage.sh also supports BarTunePackageTests executable layout (#124)', () => {
  assert.equal(fs.existsSync(exportScript), true, 'scripts/export-coverage.sh must exist');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bartune-cov-pkg-'));
  try {
    const binDir = path.join(tmp, 'debug');
    const testBin = path.join(binDir, 'BarTunePackageTests');
    const profdata = path.join(binDir, 'codecov/default.profdata');
    const output = path.join(tmp, 'coverage.lcov');

    fs.mkdirSync(path.dirname(profdata), { recursive: true });
    fs.writeFileSync(testBin, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    fs.writeFileSync(profdata, 'mock-profdata');

    const mockBin = createMockBinDir(
      tmp,
      `  echo "SF:Sources/BarTune/LyricsState.swift"
  echo "end_of_record"
  exit 0`,
    );

    execFileSync('bash', [exportScript, '--bin-path', binDir, '--profdata', profdata, '--output', output], {
      env: { ...process.env, PATH: `${mockBin}:${process.env.PATH}` },
      encoding: 'utf8',
    });

    assert.match(fs.readFileSync(output, 'utf8'), /SF:Sources\/BarTune\/LyricsState\.swift/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('export-coverage.sh fails visibly when test binary, profdata, or LCOV output is missing (#124)', () => {
  assert.equal(fs.existsSync(exportScript), true, 'scripts/export-coverage.sh must exist');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bartune-cov-err-'));
  try {
    const binDir = path.join(tmp, 'Products/Debug');
    const profdata = path.join(binDir, 'codecov/default.profdata');
    const output = path.join(tmp, 'coverage.lcov');
    fs.mkdirSync(path.dirname(profdata), { recursive: true });
    fs.writeFileSync(profdata, 'mock-profdata');

    // 1. Missing test binary
    assert.throws(
      () =>
        execFileSync('bash', [exportScript, '--bin-path', binDir, '--profdata', profdata, '--output', output], {
          encoding: 'utf8',
          stdio: 'pipe',
        }),
      (err) => err.status !== 0 && /test binary/i.test(err.stderr),
    );

    // 2. Missing profdata
    const testBin = path.join(binDir, 'BarTuneTests.xctest/Contents/MacOS/BarTuneTests');
    fs.mkdirSync(path.dirname(testBin), { recursive: true });
    fs.writeFileSync(testBin, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    fs.rmSync(profdata);

    assert.throws(
      () =>
        execFileSync('bash', [exportScript, '--bin-path', binDir, '--profdata', profdata, '--output', output], {
          encoding: 'utf8',
          stdio: 'pipe',
        }),
      (err) => err.status !== 0 && /profdata/i.test(err.stderr),
    );

    // 3. Empty LCOV output
    fs.writeFileSync(profdata, 'mock-profdata');
    const mockBin = createMockBinDir(tmp, '  exit 0');
    assert.throws(
      () =>
        execFileSync('bash', [exportScript, '--bin-path', binDir, '--profdata', profdata, '--output', output], {
          env: { ...process.env, PATH: `${mockBin}:${process.env.PATH}` },
          encoding: 'utf8',
          stdio: 'pipe',
        }),
      (err) => err.status !== 0 && /empty/i.test(err.stderr),
    );
    assert.equal(fs.existsSync(output), false, 'empty coverage file must not be left behind');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('release.yml publish-stable builds descriptive release notes with PR read permissions', () => {
  const release = readWorkflow('release.yml');
  const publishJob = extractJobBlock(release, 'publish-stable');
  assert.match(publishJob, /^\s{6}contents:\s*write\s*$/m);
  assert.match(publishJob, /^\s{6}pull-requests:\s*read\s*$/m);
  assert.match(publishJob, /fetch-depth:\s*0/);
  assert.match(publishJob, /fetch-tags:\s*true/);
  assert.match(publishJob, /node \.github\/scripts\/build-release-notes\.mjs/);
  assert.match(publishJob, /body_path:\s*release-notes\.md/);
});
