// The Risk Gate's decision. Pure: no I/O, no AI.
// gate({ rating, prAuthor, headSha, patchId, floor, mode, acceptance }) -> { check, approve }
//   rating, acceptance: the comments ({ author, body }) holding the pull request author's latest Risk Rating and
//     Risk Acceptance, or null. Untrusted: the Gate checks the author and parses the body itself.
//   headSha, patchId: the head and diff()'s patch-id, worked out by the Gate (null patchId: an empty diff).
//   floor: floor()'s result for that diff. mode: 'off' | 'shadow' | 'live'.
//   check: formatGateCheck()'s output, or null when off. approve: true only in live mode, for a Low tier, or a Medium
//     tier the Writer accepted for this patch-id.
import { TIERS, max } from './floor.js';
import { parseRating, parseAcceptance, formatGateCheck } from './rating.js';

const MODES = ['off', 'shadow', 'live'];
const cap = t => t[0].toUpperCase() + t.slice(1);
const short = sha => sha?.slice(0, 12) ?? 'none (empty diff)';

// Why the rating can't be used, or null when it can.
function unusable(rating, r, { prAuthor, headSha, patchId }) {
  if (!rating) return `No Risk Rating from @${prAuthor} yet`;
  if (rating.author !== prAuthor) return `Risk Rating posted by @${rating.author}, not the pull request's author @${prAuthor}`;
  if (!r) return 'Risk Rating comment is malformed';
  if (r.headSha !== headSha) return `Risk Rating is for an old head ${short(r.headSha)}, not ${short(headSha)}`;
  if (r.patchId !== patchId) return `Risk Rating's patch-id ${short(r.patchId)} does not match the diff's ${short(patchId)}`;
  return null;
}

export function gate({ rating, prAuthor, headSha, patchId, floor, mode, acceptance }) {
  if (!MODES.includes(mode)) throw new Error(`gate: mode must be one of ${MODES.join(', ')}, got ${mode}`);
  if (mode === 'off') return { check: null, approve: false };
  if (!TIERS.includes(floor?.tier)) throw new Error('gate: floor must be the result of floor()');

  const base = { version: 1, mode, floorTier: floor.tier, patchId, headSha };
  const r = rating?.author === prAuthor ? parseRating(rating.body) : null;
  const why = unusable(rating, r, { prAuthor, headSha, patchId });
  if (why) return { check: formatGateCheck({ ...base, tier: null, ratingTier: null, approve: false, waitingFor: 'rating', reason: why }), approve: false };

  // The Risk Floor raises the Writer's tier, never lowers it. Only the floor's own reasons go in the check: they are
  // fixed strings, where file names and the rating's summary are the pull request's text.
  const tier = max(r.tier, floor.tier);
  const floorWhy = [...new Set(floor.flags?.filter(f => f.tier === floor.tier).map(f => f.why))].join(', ');
  const reason = [tier === r.tier ? `Risk Rating ${cap(r.tier)}, Risk Floor ${cap(floor.tier)}` : `Risk Rating ${cap(r.tier)} raised to the Risk Floor ${cap(floor.tier)}`];
  if (floorWhy && tier === floor.tier && tier !== 'low') reason[0] += ` (${floorWhy})`;

  let waitingFor = tier === 'high' ? 'reviewer' : null;
  if (tier === 'medium') {
    const accepted = acceptance?.author === prAuthor ? parseAcceptance(acceptance.body) : null;
    if (accepted !== patchId) waitingFor = 'acceptance';
    reason.push(accepted === patchId ? `Risk Acceptance by @${prAuthor} for this diff` : accepted ? `latest Risk Acceptance is for an older diff ${short(accepted)}` : 'no Risk Acceptance yet');
  }
  const approve = mode === 'live' && waitingFor === null;
  return { check: formatGateCheck({ ...base, tier, ratingTier: r.tier, approve, waitingFor, reason: reason.join('; ') }), approve };
}
