// The Risk Rating comment, the Risk Comments and the Risk Acceptance, as the Work Dashboard writes them and the
// Risk Gate reads them, and the Risk Gate check, which the Gate writes and the dashboard reads. Comment bodies are
// untrusted: the readers return null for anything not exactly right.
import { TIERS, KINDS, RANK } from './floor.js';

const VERSION = 1;
const FIELDS = ['version', 'tier', 'patchId', 'headSha', 'kinds', 'floorTier', 'model', 'rulesSha', 'certain', 'summary', 'findingCount'];
const SHA = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/; // SHA-1, or SHA-256 repos
const cap = t => t[0].toUpperCase() + t.slice(1);
const line = s => typeof s === 'string' && s.trim() !== '' && !/[\r\n]/.test(s);

// A record hidden in an HTML comment, one line of JSON. < and > are escaped so nothing in it can close the comment early.
const block = (marker, record) => `<!-- ${marker}\n${JSON.stringify(record).replace(/[<>]/g, c => (c === '<' ? '\\u003c' : '\\u003e'))}\n-->`;
function readBlock(marker, body) {
  const found = [...String(body ?? '').matchAll(new RegExp(`<!-- ${marker}\\r?\\n(.*)\\r?\\n-->`, 'g'))];
  if (found.length !== 1) return null;
  try {
    return JSON.parse(found[0][1]);
  } catch {
    return null;
  }
}

function valid(r) {
  return !!r && typeof r === 'object' && !Array.isArray(r)
    && Object.keys(r).length === FIELDS.length && FIELDS.every(k => Object.hasOwn(r, k))
    && r.version === VERSION
    && TIERS.includes(r.tier) && TIERS.includes(r.floorTier) && RANK[r.tier] >= RANK[r.floorTier]
    && SHA.test(r.patchId) && SHA.test(r.headSha) && SHA.test(r.rulesSha)
    && Array.isArray(r.kinds) && r.kinds.every(k => KINDS.includes(k))
    && line(r.model) && line(r.summary) && typeof r.certain === 'boolean'
    && Number.isInteger(r.findingCount) && r.findingCount >= 0;
}

// rating: { version: 1, tier, patchId, headSha, kinds: [Change kinds present], floorTier, model, rulesSha (the main
// commit of risk/), certain, summary, findingCount }. One human line, then the record in a hidden HTML comment.
export function formatRating(rating) {
  if (!valid(rating)) throw new Error('formatRating: not a valid Risk Rating');
  const comments = rating.findingCount ? ` · ${rating.findingCount} Risk Comment${rating.findingCount > 1 ? 's' : ''}` : '';
  return `**Risk Rating: ${cap(rating.tier)}** · ${rating.summary}${comments}\n${block('risk-rating', Object.fromEntries(FIELDS.map(k => [k, rating[k]])))}`;
}

// The record from a comment body, or null when there isn't exactly one well-formed record.
export function parseRating(body) {
  const r = readBlock('risk-rating', body);
  return valid(r) ? r : null;
}

// One Risk Comment: what to check first, then the tier, the Change kind and why.
export function formatRiskComment(finding, tier) {
  const why = /[.!?…]$/.test(finding.why) ? finding.why : `${finding.why}.`;
  return `**Check:** ${finding.check} · ${cap(tier)} · ${finding.kind} · ${why}`;
}

// The patch-id a Risk Acceptance accepts, or null. `/accept-risk <patch-id>` must be a line of its own; a body
// naming two different patch-ids accepts neither.
export function parseAcceptance(body) {
  const ids = new Set([...String(body ?? '').matchAll(/^[ \t]*\/accept-risk[ \t]+([0-9a-f]{40}(?:[0-9a-f]{24})?)[ \t]*\r?$/gm)].map(m => m[1]));
  return ids.size === 1 ? [...ids][0] : null;
}

// The Risk Gate check. It never fails (conclusion is always success): the title says what the pull request waits for.
// result: { version: 1, mode: 'off'|'shadow'|'live', tier: the Gate's tier or null with no usable Risk Rating,
//   ratingTier, floorTier, patchId (the Gate's own, null for an empty diff), headSha, approve,
//   waitingFor: null|'rating'|'acceptance'|'reviewer', reason: one line }
const GATE_FIELDS = ['version', 'mode', 'tier', 'ratingTier', 'floorTier', 'patchId', 'headSha', 'approve', 'waitingFor', 'reason'];
const MODES = ['off', 'shadow', 'live'];
const WAITING = { rating: 'waiting for a Risk Rating', acceptance: "waiting for the Writer's Risk Acceptance", reviewer: "needs another engineer's approval" };
const tierOrNull = t => t === null || TIERS.includes(t);
const atLeast = (t, other) => other === null || RANK[t] >= RANK[other];

function validGate(g) {
  return !!g && typeof g === 'object' && !Array.isArray(g)
    && Object.keys(g).length === GATE_FIELDS.length && GATE_FIELDS.every(k => Object.hasOwn(g, k))
    && g.version === VERSION && MODES.includes(g.mode)
    && tierOrNull(g.tier) && tierOrNull(g.ratingTier) && tierOrNull(g.floorTier)
    && (g.tier === null || (atLeast(g.tier, g.ratingTier) && atLeast(g.tier, g.floorTier))) // raised to the Risk Floor, never lowered
    && (g.patchId === null || SHA.test(g.patchId)) && SHA.test(g.headSha)
    && typeof g.approve === 'boolean' && (g.waitingFor === null || Object.hasOwn(WAITING, g.waitingFor))
    && line(g.reason)
    // The Risk Bot approves only live, only a rated Low or Medium change, and only when nothing is outstanding.
    && (!g.approve || (g.mode === 'live' && (g.tier === 'low' || g.tier === 'medium') && g.waitingFor === null));
}

export function formatGateCheck(result) {
  if (!validGate(result)) throw new Error('formatGateCheck: not a valid Risk Gate result');
  const { mode, tier, approve, waitingFor } = result;
  const tag = mode === 'live' ? '' : ` (${mode})`;
  const what = waitingFor ? WAITING[waitingFor] : approve ? 'approved by the Risk Bot' : mode === 'live' ? 'not approved' : 'would be approved';
  const title = mode === 'off' ? 'Risk Gate off'
    : waitingFor === 'rating' || tier === null ? `Waiting for a Risk Rating${tag}`
      : `${cap(tier)}${tag}: ${what}`;
  return { name: 'Risk Gate', conclusion: 'success', title, summary: `${result.reason}\n${block('risk-gate', Object.fromEntries(GATE_FIELDS.map(k => [k, result[k]])))}` };
}

// The Gate's result from a check summary, or null when there isn't exactly one well-formed record.
export function parseGateCheck(summary) {
  const g = readBlock('risk-gate', summary);
  return validGate(g) ? g : null;
}
