import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gate } from '../gate.js';
import { formatRating, parseGateCheck } from '../rating.js';

const sha = c => c.repeat(40);
const HEAD = sha('b');
const PATCH = sha('a');
const rating = (over = {}, author = 'writer') => ({
  author,
  body: formatRating({ version: 1, tier: 'low', patchId: PATCH, headSha: HEAD, kinds: [], floorTier: 'low', model: 'claude-sonnet-5-5', rulesSha: sha('c'), certain: true, summary: 'ui-copy on app (Tier 3)', findingCount: 0, ...over }),
});
const accept = (id = PATCH, author = 'writer') => ({ author, body: `Read the Risk Comments.\n/accept-risk ${id}` });
const floor = (tier = 'low', why = 'money path') => ({ tier, systems: ['app'], systemTier: 3, flags: tier === 'low' ? [] : [{ kind: 'money-path', file: 'src/billing.js', tier, why }] });
const input = (over = {}) => ({ rating: rating(), prAuthor: 'writer', headSha: HEAD, patchId: PATCH, floor: floor(), mode: 'live', acceptance: null, ...over });

// [name, input overrides, approve, check title, reason pattern]
const cases = [
  ['no rating', { rating: null }, false, 'Waiting for a Risk Rating', /^No Risk Rating from @writer yet$/],
  ['wrong author', { rating: rating({}, 'mallory') }, false, 'Waiting for a Risk Rating', /posted by @mallory, not the pull request's author @writer/],
  ['malformed rating', { rating: { author: 'writer', body: '**Risk Rating: Low** · trust me' } }, false, 'Waiting for a Risk Rating', /malformed/],
  ['old head', { rating: rating({ headSha: sha('d') }) }, false, 'Waiting for a Risk Rating', /old head dddddddddddd, not bbbbbbbbbbbb/],
  ['patch-id mismatch', { patchId: sha('e') }, false, 'Waiting for a Risk Rating', /patch-id aaaaaaaaaaaa does not match the diff's eeeeeeeeeeee/],
  ['empty diff', { patchId: null }, false, 'Waiting for a Risk Rating', /the diff's none \(empty diff\)/],
  ['live Low approves', {}, true, 'Low: approved by the Risk Bot', /^Risk Rating Low, Risk Floor Low$/],
  ['shadow Low never approves', { mode: 'shadow' }, false, 'Low (shadow): would be approved', /^Risk Rating Low, Risk Floor Low$/],
  ['floor raises a Low rating', { floor: floor('medium') }, false, "Medium: waiting for the Writer's Risk Acceptance", /^Risk Rating Low raised to the Risk Floor Medium \(money path\); no Risk Acceptance yet$/],
  ['live Medium without acceptance', { rating: rating({ tier: 'medium' }) }, false, "Medium: waiting for the Writer's Risk Acceptance", /no Risk Acceptance yet/],
  ['live Medium with matching acceptance', { rating: rating({ tier: 'medium' }), acceptance: accept() }, true, 'Medium: approved by the Risk Bot', /Risk Acceptance by @writer for this diff/],
  ['acceptance for an old patch-id', { rating: rating({ tier: 'medium' }), acceptance: accept(sha('f')) }, false, "Medium: waiting for the Writer's Risk Acceptance", /older diff ffffffffffff/],
  ['acceptance by someone else', { rating: rating({ tier: 'medium' }), acceptance: accept(PATCH, 'mallory') }, false, "Medium: waiting for the Writer's Risk Acceptance", /no Risk Acceptance yet/],
  ['shadow Medium with acceptance never approves', { mode: 'shadow', rating: rating({ tier: 'medium' }), acceptance: accept() }, false, 'Medium (shadow): would be approved', /for this diff/],
  ['live High never approves', { rating: rating({ tier: 'high', floorTier: 'low', findingCount: 1 }), acceptance: accept() }, false, "High: needs another engineer's approval", /^Risk Rating High, Risk Floor Low$/],
  ['floor raises to High', { floor: floor('high', 'migration or SQL file'), acceptance: accept() }, false, "High: needs another engineer's approval", /raised to the Risk Floor High \(migration or SQL file\)$/],
];

for (const [name, over, approve, title, reason] of cases) {
  test(`gate: ${name}`, () => {
    const out = gate(input(over));
    assert.equal(out.approve, approve);
    assert.equal(out.check.title, title);
    assert.equal(out.check.conclusion, 'success', 'the Risk Gate check never fails');
    const result = parseGateCheck(out.check.summary);
    assert.ok(result, 'the dashboard can read the check back');
    assert.equal(result.approve, approve);
    assert.match(result.reason, reason);
    assert.doesNotMatch(JSON.stringify(out.check), /generated|co-authored|🤖|claude-sonnet|ui-copy on app|src\/billing/i, 'no AI attribution, and none of the PR\'s text');
  });
}

test('gate: the tier is the higher of the Risk Rating and the Risk Floor', () => {
  const tier = (r, f) => parseGateCheck(gate(input({ rating: rating({ tier: r, floorTier: 'low', findingCount: r === 'low' ? 0 : 1 }), floor: floor(f) })).check.summary);
  const raised = tier('low', 'medium');
  assert.deepEqual([raised.tier, raised.ratingTier, raised.floorTier], ['medium', 'low', 'medium']);
  assert.equal(tier('high', 'low').tier, 'high', 'the Gate never lowers the rating to the floor');
  assert.equal(tier('medium', 'high').tier, 'high');
});

test('gate: off posts nothing and approves nothing', () => {
  assert.deepEqual(gate(input({ mode: 'off' })), { check: null, approve: false });
  assert.deepEqual(gate(input({ mode: 'off', rating: null })), { check: null, approve: false });
});

test('gate: refuses an unknown mode or a missing floor instead of guessing', () => {
  assert.throws(() => gate(input({ mode: 'Live' })), /mode/);
  assert.throws(() => gate(input({ floor: undefined })), /floor/);
});
