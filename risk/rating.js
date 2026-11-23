// The Risk Rating comment, the Risk Comments and the Risk Acceptance, as the Work Dashboard writes them and the
// Risk Gate reads them. Comment bodies are untrusted: the readers return null for anything not exactly right.
import { TIERS, KINDS, RANK } from './floor.js';

const VERSION = 1;
const FIELDS = ['version', 'tier', 'patchId', 'headSha', 'kinds', 'floorTier', 'model', 'rulesSha', 'certain', 'summary', 'findingCount'];
const SHA = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/; // SHA-1, or SHA-256 repos
const BLOCK = /<!-- risk-rating\r?\n(.*)\r?\n-->/g;
const cap = t => t[0].toUpperCase() + t.slice(1);
const line = s => typeof s === 'string' && s.trim() !== '' && !/[\r\n]/.test(s);

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
  // < and > are escaped so nothing in the record can close the HTML comment early.
  const record = JSON.stringify(Object.fromEntries(FIELDS.map(k => [k, rating[k]]))).replace(/[<>]/g, c => (c === '<' ? '\\u003c' : '\\u003e'));
  return `**Risk Rating: ${cap(rating.tier)}** · ${rating.summary}${comments}\n<!-- risk-rating\n${record}\n-->`;
}

// The record from a comment body, or null when there isn't exactly one well-formed record.
export function parseRating(body) {
  const blocks = [...String(body ?? '').matchAll(BLOCK)];
  if (blocks.length !== 1) return null;
  try {
    const r = JSON.parse(blocks[0][1]);
    return valid(r) ? r : null;
  } catch {
    return null;
  }
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
