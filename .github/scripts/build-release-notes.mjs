#!/usr/bin/env node
/**
 * Builds human-readable GitHub Release notes for a BarTune stable release by combining
 * each merged PR's plain-language `## Summary` (falling back to `## What changed and why`
 * or the commit body) with an Install/Upgrade guide, the full list of merged PRs, and the
 * compare link from the previous stable `v*` tag.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const CATEGORY_ORDER = [
  { key: 'breaking', heading: '### Breaking Changes' },
  { key: 'feat', heading: '### Features' },
  { key: 'perf', heading: '### Performance' },
  { key: 'fix', heading: '### Bug Fixes' },
  { key: 'other', heading: '### Other Changes' },
];

const VERSION_BUMP_RE = /^chore(?:\(build\))?:\s*(?:bump version|release)\b/i;
const CONVENTIONAL_RE = /^([a-z]+)(?:\([^)]+\))?(!)?:\s*(.+)$/i;

/**
 * Extracts the plain-language text of a markdown `## <Heading>` section, stripping HTML comments.
 */
export function extractMarkdownSection(body, heading) {
  if (!body || typeof body !== 'string') return '';
  const lines = body.replace(/\r\n/g, '\n').split('\n');
  const target = `## ${heading.toLowerCase()}`;
  let capturing = false;
  const collected = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (/^##\s+/.test(trimmed)) {
      if (capturing) break;
      if (trimmed.toLowerCase() === target) {
        capturing = true;
      }
      continue;
    }
    if (capturing) {
      collected.push(line);
    }
  }

  return collected
    .join('\n')
    .replace(/<!--[\s\S]*?-->/g, '')
    .trim();
}

/**
 * Extracts a concise, user-facing description from a PR body or commit body.
 */
export function extractReleaseSummary({ body, commitBody } = {}) {
  const fromSummary = extractMarkdownSection(body, 'Summary');
  if (fromSummary) return collapseParagraphs(fromSummary);

  const fromWhatChanged = extractMarkdownSection(body, 'What changed and why');
  if (fromWhatChanged) {
    const cleaned = fromWhatChanged
      .split('\n')
      .filter((line) => !/^\s*(?:closes|fixes|resolves)\s+#\d+\.?\s*$/i.test(line))
      .join('\n')
      .trim();
    if (cleaned) return collapseParagraphs(cleaned);
  }

  if (commitBody && typeof commitBody === 'string') {
    const cleaned = commitBody
      .replace(/\r\n/g, '\n')
      .split('\n')
      .filter((line) => !/^\s*(?:(?:Co-Authored-By|Signed-off-by):|(?:Closes|Fixes|Resolves)\s+#\d+)/i.test(line))
      .join('\n')
      .trim();
    if (cleaned) return collapseParagraphs(cleaned);
  }

  return '';
}

function collapseParagraphs(markdown) {
  // Keep the first paragraph (or bullet list block) so release highlights stay scannable.
  const blocks = markdown
    .split(/\n{2,}/)
    .map((block) => block.trim())
    .filter(Boolean);
  if (blocks.length === 0) return '';
  return blocks[0]
    .split('\n')
    .map((line) => line.trim())
    .join(' ');
}

export function classifyEntry(title, labels = []) {
  const lowerLabels = new Set(labels.map((l) => String(l).toLowerCase()));
  const match = String(title || '').trim().match(CONVENTIONAL_RE);
  const type = match ? match[1].toLowerCase() : '';
  const isBreaking = Boolean(match && match[2] === '!');

  if (isBreaking) return 'breaking';
  if (type === 'feat' || lowerLabels.has('enhancement')) return 'feat';
  if (type === 'perf' || lowerLabels.has('performance')) return 'perf';
  if (type === 'fix' || lowerLabels.has('bug')) return 'fix';
  return 'other';
}

export function humanizeTitle(title) {
  const trimmed = String(title || '').trim();
  const match = trimmed.match(CONVENTIONAL_RE);
  const raw = match ? match[3].trim() : trimmed;
  if (!raw) return trimmed;
  return raw[0].toUpperCase() + raw.slice(1);
}

export function isVersionBumpEntry(title) {
  return VERSION_BUMP_RE.test(String(title || '').trim());
}

export function isIgnoredForRelease(labels = []) {
  return labels.some((label) => String(label).toLowerCase() === 'ignore-for-release');
}

/**
 * Renders complete release notes markdown from structured inputs.
 */
export function renderReleaseNotes({
  version,
  tag,
  previousTag,
  repo,
  entries,
}) {
  const lines = [];
  lines.push(`## What's Included in BarTune ${tag}`);
  lines.push('');

  const includedEntries = entries.filter((entry) => !isIgnoredForRelease(entry.labels));
  const highlightEntries = includedEntries.filter((entry) => !isVersionBumpEntry(entry.title));
  const grouped = new Map(CATEGORY_ORDER.map((c) => [c.key, []]));
  for (const entry of highlightEntries) {
    const category = classifyEntry(entry.title, entry.labels);
    grouped.get(category).push(entry);
  }

  let wroteCategory = false;
  for (const { key, heading } of CATEGORY_ORDER) {
    const items = grouped.get(key);
    if (!items || items.length === 0) continue;
    wroteCategory = true;
    lines.push(heading);
    lines.push('');
    for (const item of items) {
      const ref = item.number
        ? ` ([#${item.number}](https://github.com/${repo}/pull/${item.number}))`
        : item.sha
          ? ` (\`${item.sha.slice(0, 7)}\`)`
          : '';
      const headline = humanizeTitle(item.title);
      const summary = extractReleaseSummary(item);
      if (summary) {
        lines.push(`- **${headline}**${ref} — ${summary}`);
      } else {
        lines.push(`- **${headline}**${ref}`);
      }
    }
    lines.push('');
  }

  if (!wroteCategory) {
    lines.push('Maintenance release with build and packaging updates.');
    lines.push('');
  }

  lines.push('## Install or Upgrade');
  lines.push('');
  lines.push('- **Homebrew:** `brew upgrade --cask bartune` (or `brew install --cask TrigrD3/tap/bartune`)');
  lines.push(
    `- **Manual:** Download \`BarTune-${version}.dmg\` and \`BarTune-${version}.dmg.sha256\` into the same directory, verify with \`shasum -a 256 -c BarTune-${version}.dmg.sha256\`, open the DMG, and drag **BarTune.app** to Applications.`,
  );
  lines.push('- **Requirements:** macOS 13.0 (Ventura)+ on Apple Silicon (Intel Macs can build from source).');
  lines.push('');

  const prEntries = includedEntries.filter((entry) => entry.number);
  if (prEntries.length > 0) {
    lines.push('## Merged Pull Requests');
    lines.push('');
    for (const pr of prEntries) {
      const author = pr.author ? ` by @${pr.author}` : '';
      lines.push(`- ${pr.title}${author} in #${pr.number}`);
    }
    lines.push('');
  }

  if (previousTag) {
    lines.push(`**Full Changelog**: https://github.com/${repo}/compare/${previousTag}...${tag}`);
  }

  return `${lines.join('\n').trimEnd()}\n`;
}

function git(args) {
  return execFileSync('git', args, { encoding: 'utf8' }).trim();
}

export function findPreviousStableTag(currentTag, currentRef = 'HEAD') {
  const tagsOutput = git(['tag', '--merged', currentRef, '--list', 'v*', '--sort=-v:refname']);
  const tags = tagsOutput
    .split('\n')
    .map((t) => t.trim())
    .filter((t) => /^v\d+\.\d+\.\d+$/.test(t) && t !== currentTag);
  return tags[0] || '';
}

function listCommitsSince(previousTag, currentRef) {
  const range = previousTag ? `${previousTag}..${currentRef}` : currentRef;
  const format = '%H%x1f%s%x1f%b%x1e';
  const raw = git(['log', '--reverse', `--format=${format}`, range]);
  if (!raw) return [];
  return raw
    .split('\x1e')
    .map((record) => record.trim())
    .filter(Boolean)
    .map((record) => {
      const [sha = '', subject = '', body = ''] = record.split('\x1f');
      return { sha: sha.trim(), subject: subject.trim(), commitBody: body.trim() };
    });
}

async function fetchAssociatedPRs(repo, sha, token) {
  if (!token) return [];
  const url = `https://api.github.com/repos/${repo}/commits/${sha}/pulls`;
  const response = await fetch(url, {
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'bartune-release-notes',
    },
  });
  if (!response.ok) {
    return [];
  }
  const data = await response.json();
  return Array.isArray(data) ? data : [];
}

async function collectReleaseEntries({ repo, previousTag, currentRef, token }) {
  const commits = listCommitsSince(previousTag, currentRef);
  const seenPRs = new Set();
  const entries = [];

  for (const commit of commits) {
    const prs = await fetchAssociatedPRs(repo, commit.sha, token);
    const mergedPR = prs.find((pr) => pr && pr.merged_at);
    if (mergedPR) {
      if (seenPRs.has(mergedPR.number)) continue;
      seenPRs.add(mergedPR.number);
      entries.push({
        number: mergedPR.number,
        title: mergedPR.title,
        body: mergedPR.body || '',
        author: mergedPR.user?.login || '',
        labels: Array.isArray(mergedPR.labels) ? mergedPR.labels.map((l) => l.name).filter(Boolean) : [],
        sha: commit.sha,
        commitBody: commit.commitBody,
      });
    } else {
      entries.push({
        number: null,
        title: commit.subject,
        body: '',
        author: '',
        labels: [],
        sha: commit.sha,
        commitBody: commit.commitBody,
      });
    }
  }
  return entries;
}

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith('--') && i + 1 < argv.length) {
      opts[arg.slice(2)] = argv[i + 1];
      i += 1;
    }
  }
  return opts;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const version = opts.version || process.env.VERSION || fs.readFileSync('VERSION', 'utf8').trim();
  const tag = opts.tag || process.env.TAG || `v${version}`;
  const repo = opts.repo || process.env.GITHUB_REPOSITORY || 'TrigrD3/bartune';
  const currentRef = opts.ref || process.env.GITHUB_SHA || 'HEAD';
  const outputPath = opts.output || '';
  const previousTag = opts['previous-tag'] ?? findPreviousStableTag(tag, currentRef);
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN || '';

  const entries = await collectReleaseEntries({ repo, previousTag, currentRef, token });
  const markdown = renderReleaseNotes({ version, tag, previousTag, repo, entries });

  if (outputPath) {
    fs.writeFileSync(outputPath, markdown, 'utf8');
  } else {
    process.stdout.write(markdown);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
