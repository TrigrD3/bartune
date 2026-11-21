export const SEVERITY_LABELS = {
  critical: {
    label: 'severity: critical',
    color: 'b60205',
    description: 'Crash, data loss, security vulnerability, or app unusable',
  },
  high: {
    label: 'severity: high',
    color: 'd93f0b',
    description: 'Major functionality broken with no easy workaround',
  },
  medium: {
    label: 'severity: medium',
    color: 'fbca04',
    description: 'Noticeable issue or degraded experience with a workaround',
  },
  low: {
    label: 'severity: low',
    color: '0e8a16',
    description: 'Minor glitch, cosmetic issue, or low-impact edge case',
  },
};

export const ALL_SEVERITY_LABEL_NAMES = Object.values(SEVERITY_LABELS).map(
  (entry) => entry.label,
);

const NON_BUG_SKIP_LABELS = new Set([
  'enhancement',
  'documentation',
  'question',
]);

const KEYWORD_RULES = [
  {
    level: 'critical',
    pattern:
      /\b(crash(?:es|ed|ing)?|segfault|sigsegv|sigabrt|exc_bad_access|fatal(?:\s+error)?|kernel\s+panic|unusable|won'?t\s+(?:launch|start|open)|fails?\s+to\s+(?:launch|start|open)|data\s+loss|corrupt(?:s|ed|ion)?|security|vulnerabilit(?:y|ies)|cve-\d+|rce|xss|injection|leaks?\s+(?:memory|mach|port|handle|fd|file\s+descriptor|thread|send\s+rights)|memory\s+leak|unbounded\s+(?:growth|memory)|grows?\s+without\s+bound|oom|out\s+of\s+memory|hangs?\s+indefinitely|deadlock|freez(?:e[sd]?|ing))\b/i,
  },
  {
    level: 'high',
    pattern:
      /\b(broken|doesn'?t\s+work|does\s+not\s+work|not\s+working|unable\s+to|fails?\s+to|cannot|can'?t|regression|arm64-only|x86_64|intel\s+mac|unsupported\s+architecture|wrong\s+(?:lyrics|timing|offset)|out\s+of\s+sync|never\s+(?:updates?|loads?|syncs?|shows?)|always\s+fails?|blocks?|blocking|high\s+cpu|100%\s+cpu|truncat(?:es|ed|ing)|drops?\s+(?:leading|trailing|lyrics|text|lines?)|ignores?\s+(?:the\s+)?\[?offset\]?|leaves?\s+stale|stale\s+cache)\b/i,
  },
  {
    level: 'medium',
    pattern:
      /\b(flicker(?:s|ing)?|glitch(?:es|y)?|stutter(?:s|ing)?|lag(?:s|gy|ging)?|slow(?:s|down)?|delay(?:s|ed)?|inconsistent|intermittent|sometimes|occasionally|unexpected|misalign(?:ed|ment)?|overlap(?:s|ping)?|clipp(?:ed|ing)|cut\s+off|duplicate[sd]?|workaround)\b/i,
  },
  {
    level: 'low',
    pattern:
      /\b(typo|cosmetic|visual\s+nit|minor|nitpick|polish|text\s+alignment|ui\s+alignment|spacing|padding|color|colour|font|icon|tooltip|label\s+text|copy|wording|spelling)\b/i,
  },
];

/**
 * Parses the Severity field from a GitHub Issue Form body (e.g. "### Severity\n\nHigh — ...").
 * Returns 'critical' | 'high' | 'medium' | 'low' | null.
 */
export function parseDropdownSeverity(body) {
  if (!body || typeof body !== 'string') {
    return null;
  }

  const match = body.match(
    /^###\s+Severity\s*\r?\n+([^\r\n#][^\r\n]*)/im,
  );
  if (!match) {
    return null;
  }

  const value = match[1].trim();
  if (!value || /^_no response_$/i.test(value)) {
    return null;
  }

  const levelMatch = value.match(/^(critical|high|medium|low)\b/i);
  return levelMatch ? levelMatch[1].toLowerCase() : null;
}

/**
 * Infers severity from issue title and body using ordered keyword heuristics.
 * Returns 'critical' | 'high' | 'medium' | 'low' | null.
 */
export function inferKeywordSeverity(title, body) {
  const combined = `${title || ''}\n${body || ''}`;
  for (const rule of KEYWORD_RULES) {
    if (rule.pattern.test(combined)) {
      return rule.level;
    }
  }
  return null;
}

/**
 * Resolves the target severity label and any stale severity labels to remove.
 *
 * @param {object} params
 * @param {string} params.title - Issue title
 * @param {string} params.body - Issue body
 * @param {string[]} params.labels - Current label names on the issue
 * @returns {{
 *   level: string | null,
 *   targetLabel: string | null,
 *   source: 'dropdown' | 'existing' | 'skipped' | 'keywords' | 'default-bug' | 'default',
 *   shouldAdd: boolean,
 *   labelsToRemove: string[],
 *   changed: boolean,
 * }}
 */
export function resolveIssueSeverity({ title = '', body = '', labels = [] }) {
  const normalizedLabels = labels.map((l) => l.toLowerCase());
  const existingSeverityLabels = labels.filter((l) =>
    ALL_SEVERITY_LABEL_NAMES.includes(l.toLowerCase()),
  );

  // 1. Explicit Severity dropdown in the issue form always takes precedence.
  const dropdownLevel = parseDropdownSeverity(body);
  if (dropdownLevel) {
    const targetLabel = SEVERITY_LABELS[dropdownLevel].label;
    const hasTarget = existingSeverityLabels.some(
      (l) => l.toLowerCase() === targetLabel,
    );
    const labelsToRemove = existingSeverityLabels.filter(
      (l) => l.toLowerCase() !== targetLabel,
    );
    return {
      level: dropdownLevel,
      targetLabel,
      source: 'dropdown',
      shouldAdd: !hasTarget,
      labelsToRemove,
      changed: !hasTarget || labelsToRemove.length > 0,
    };
  }

  // 2. Preserve any existing severity label (e.g., set manually by a maintainer).
  if (existingSeverityLabels.length > 0) {
    return {
      level: null,
      targetLabel: null,
      source: 'existing',
      shouldAdd: false,
      labelsToRemove: [],
      changed: false,
    };
  }

  // 3. Skip non-bug issues (enhancements, docs, questions) unless explicitly tagged as bugs.
  const isBug = normalizedLabels.includes('bug');
  const isNonBug = normalizedLabels.some((l) => NON_BUG_SKIP_LABELS.has(l));
  if (isNonBug && !isBug) {
    return {
      level: null,
      targetLabel: null,
      source: 'skipped',
      shouldAdd: false,
      labelsToRemove: [],
      changed: false,
    };
  }

  // 4. Fallback to deterministic keyword heuristics, then a sensible default.
  const keywordLevel = inferKeywordSeverity(title, body);
  if (keywordLevel) {
    return {
      level: keywordLevel,
      targetLabel: SEVERITY_LABELS[keywordLevel].label,
      source: 'keywords',
      shouldAdd: true,
      labelsToRemove: [],
      changed: true,
    };
  }

  const defaultLevel = isBug ? 'medium' : 'low';
  return {
    level: defaultLevel,
    targetLabel: SEVERITY_LABELS[defaultLevel].label,
    source: isBug ? 'default-bug' : 'default',
    shouldAdd: true,
    labelsToRemove: [],
    changed: true,
  };
}
