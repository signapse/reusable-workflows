// Turns the Risk Check's JSON answer into the pull request's Risk tier, Risk Comments and summary. Pure: no I/O.
// decide(answer, { floor, readLines }) -> { ok: true, tier, certain, modelTier, rubricTier, floorTier, findings, summary }
//                                       | { ok: false, error }
//   floor:     floor()'s result for this diff ({ tier, systems, systemTier }).
//   readLines: path -> the new file's lines (index 0 = line 1), or undefined when it can't be read. Optional.
import { TIERS, KINDS, RANK, max, rubricTier, isTestOrDoc } from './floor.js';

const MAX_FINDINGS = 5;
const WHY_WORDS = 12;
const CHECK_WORDS = 10;

function invalid(a) {
  if (!a || typeof a !== 'object' || Array.isArray(a)) return 'the answer is not a JSON object';
  if (!TIERS.includes(a.tier)) return `tier must be one of ${TIERS.join(', ')}`;
  if (typeof a.certain !== 'boolean') return 'certain must be true or false';
  if (!a.kinds || typeof a.kinds !== 'object' || Array.isArray(a.kinds)) return 'kinds must be an object';
  const missing = KINDS.filter(k => typeof a.kinds[k] !== 'boolean');
  if (missing.length) return `kinds must say true or false for: ${missing.join(', ')}`;
  const unknown = Object.keys(a.kinds).filter(k => !KINDS.includes(k));
  if (unknown.length) return `unknown Change kinds: ${unknown.join(', ')}`;
  if (!Array.isArray(a.findings)) return 'findings must be an array';
  const bad = a.findings.findIndex(f => !f || typeof f !== 'object'
    || !['file', 'system', 'why', 'check'].every(k => typeof f[k] === 'string' && f[k].trim())
    || !Number.isInteger(f.line) || f.line < 1 || !KINDS.includes(f.kind));
  if (bad >= 0) return `finding ${bad + 1} needs file, line (a whole number from 1), system, kind (a Change kind), why and check`;
  if (a.tier !== 'low' && !a.findings.length) return 'a Medium or High tier needs at least one finding';
}

// Over-long text is trimmed, not rejected: the model often runs a word or two over, and a rerun costs the Writer's
// plan. The "…" shows a human it was cut. Newlines and runs of spaces collapse to one space.
function words(text, limit) {
  const w = text.split(/\s+/).filter(Boolean);
  return w.length > limit ? `${w.slice(0, limit).join(' ')}…` : w.join(' ');
}

// A Risk Comment on `}` or `);` (or past the end of the file) tells nobody anything: move it to the nearest line with
// a letter or digit, looking above first (a closing bracket ends the code before it).
const isCode = line => /[\p{L}\p{N}]/u.test(line ?? '');
function codeLine(lines, line) {
  if (!lines?.length) return line;
  const at = Math.min(line, lines.length);
  for (let d = 0; d < lines.length; d++) {
    if (isCode(lines[at - 1 - d])) return at - d;
    if (isCode(lines[at - 1 + d])) return at + d;
  }
  return line;
}

export function decide(answer, { floor, readLines } = {}) {
  const error = invalid(answer);
  if (error) return { ok: false, error };
  if (!TIERS.includes(floor?.tier) || !Array.isArray(floor.systems)) throw new Error('decide: ctx.floor must be the result of floor()');

  // Unsure raises the Risk Check's tier one step; the final tier is the highest of the Risk Check, the Rubric and the Risk Floor.
  const checkTier = answer.certain ? answer.tier : TIERS[Math.min(RANK[answer.tier] + 1, TIERS.length - 1)];
  const tableTier = rubricTier(answer.kinds, floor.systemTier);
  const tier = [checkTier, tableTier, floor.tier].reduce(max);

  // Risk Comments: Medium and High only, never on tests or docs, at most five, most severe first as the model listed them.
  const findings = tier === 'low' ? [] : answer.findings
    .filter(f => !isTestOrDoc(f.file))
    .slice(0, MAX_FINDINGS)
    .map(f => ({ file: f.file, line: codeLine(readLines?.(f.file), f.line), system: f.system, kind: f.kind, why: words(f.why, WHY_WORDS), check: words(f.check, CHECK_WORDS) }));

  const kinds = KINDS.filter(k => answer.kinds[k]).join(', ') || 'no Change kinds';
  const where = floor.systems.length ? `${floor.systems.join(', ')} (Tier ${floor.systemTier})` : 'tests and docs only';
  const setBy = [['the Risk Check', checkTier], ['the Rubric', tableTier], ['the Risk Floor', floor.tier]].filter(([, t]) => t === tier).map(([who]) => who);
  const summary = tier === 'low'
    ? `${kinds} on ${where}`
    : `${kinds} on ${where}; tier from ${setBy.join(', ').replace(/, (?=[^,]*$)/, ' and ')}${answer.certain ? '' : ' (Risk Check unsure)'}`;

  return { ok: true, tier, certain: answer.certain, modelTier: answer.tier, rubricTier: tableTier, floorTier: floor.tier, findings, summary };
}
