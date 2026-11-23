import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatRating, parseRating, formatRiskComment, parseAcceptance, formatGateCheck, parseGateCheck } from '../rating.js';

const sha = c => c.repeat(40);
const rating = (over = {}) => ({
  version: 1, tier: 'high', patchId: sha('a'), headSha: sha('b'), kinds: ['data', 'money'], floorTier: 'medium',
  model: 'claude-sonnet-5-5', rulesSha: sha('c'), certain: true, summary: 'data, money on billing (Tier 1); tier from the Rubric', findingCount: 3, ...over,
});

test('formatRating: one human line, then the record hidden in an HTML comment', () => {
  const body = formatRating(rating());
  const [first, ...rest] = body.split('\n');
  assert.equal(first, '**Risk Rating: High** · data, money on billing (Tier 1); tier from the Rubric · 3 Risk Comments');
  assert.equal(rest[0], '<!-- risk-rating');
  assert.equal(rest.at(-1), '-->');
  assert.doesNotMatch(body, /generated|co-authored|🤖/i);
  assert.equal(formatRating(rating({ tier: 'low', floorTier: 'low', findingCount: 0 })).split('\n')[0], '**Risk Rating: Low** · data, money on billing (Tier 1); tier from the Rubric');
});

test('parseRating reads back exactly what formatRating wrote', () => {
  for (const r of [rating(), rating({ tier: 'low', floorTier: 'low', kinds: [], certain: false, findingCount: 0 }), rating({ patchId: 'd'.repeat(64) })]) {
    assert.deepEqual(parseRating(formatRating(r)), r);
  }
  assert.deepEqual(parseRating(`Thanks!\r\n\r\n${formatRating(rating()).replaceAll('\n', '\r\n')}`), rating(), 'CRLF from the GitHub UI');
});

test('nothing in the record can close the hidden comment early', () => {
  const r = rating({ summary: 'a --> b <!-- risk-rating', model: 'x-->' });
  const body = formatRating(r);
  assert.equal(body.match(/-->/g).length, 2, 'the one in the human line, and the real end');
  assert.deepEqual(parseRating(body), r);
});

test('parseRating rejects bodies without exactly one well-formed record', () => {
  const block = json => `**Risk Rating: Low** · x\n<!-- risk-rating\n${json}\n-->`;
  const ok = JSON.stringify(rating());
  const bad = [
    undefined, '', 'LGTM', '/accept-risk ' + sha('a'),
    block('{not json'),
    formatRating(rating()) + '\n' + formatRating(rating()),
    block(JSON.stringify({ ...rating(), version: 2 })),
    block(JSON.stringify({ ...rating(), extra: 1 })),
    block(JSON.stringify({ ...rating(), certain: undefined })),
    block(JSON.stringify({ ...rating(), tier: 'severe' })),
    block(JSON.stringify({ ...rating(), tier: 'low', floorTier: 'medium' })),
    block(JSON.stringify({ ...rating(), patchId: 'abc' })),
    block(JSON.stringify({ ...rating(), headSha: sha('B') })),
    block(JSON.stringify({ ...rating(), kinds: ['security'] })),
    block(JSON.stringify({ ...rating(), findingCount: -1 })),
    block(JSON.stringify({ ...rating(), summary: 'two\nlines' })),
    block('[' + ok + ']'),
  ];
  for (const body of bad) assert.equal(parseRating(body), null, String(body));
});

test('formatRating refuses an invalid rating instead of writing one the Risk Gate would reject', () => {
  assert.throws(() => formatRating(rating({ tier: 'severe' })));
  assert.throws(() => formatRating({ tier: 'low' }));
});

test('formatRiskComment leads with the check, then tier, Change kind and why', () => {
  const finding = { file: 'm.sql', line: 3, system: 'app', kind: 'data', why: 'Adds three columns to a live table', check: 'Confirm down migration restores the column' };
  assert.equal(formatRiskComment(finding, 'high'), '**Check:** Confirm down migration restores the column · High · data · Adds three columns to a live table.');
  assert.match(formatRiskComment({ ...finding, why: 'Already ends.' }, 'medium'), /· Medium · data · Already ends\.$/);
  assert.match(formatRiskComment({ ...finding, why: 'Trimmed…' }, 'medium'), /Trimmed…$/);
});

test('parseAcceptance: the patch-id of an /accept-risk line', () => {
  const id = sha('e');
  assert.equal(parseAcceptance(`/accept-risk ${id}`), id);
  assert.equal(parseAcceptance(`Read the Risk Comments.\r\n  /accept-risk ${id}  \r\n`), id);
  assert.equal(parseAcceptance(`/accept-risk ${id}\n/accept-risk ${id}`), id);
  assert.equal(parseAcceptance(`/accept-risk ${'f'.repeat(64)}`), 'f'.repeat(64));
});

test('parseAcceptance: null for anything else', () => {
  const id = sha('e');
  for (const body of [
    undefined, '', '/accept-risk', '/accept-risk abc123', `/accept-risk ${id.toUpperCase()}`, `/accept-risk ${id}0`,
    `please /accept-risk ${id}`, `> /accept-risk ${id}`, `/accept-risk ${id} and more`,
    `/accept-risk ${id}\n/accept-risk ${sha('f')}`,
  ]) assert.equal(parseAcceptance(body), null, String(body));
});

const gate = (over = {}) => ({
  version: 1, mode: 'shadow', tier: 'high', ratingTier: 'medium', floorTier: 'high', patchId: sha('a'), headSha: sha('b'),
  approve: false, waitingFor: 'reviewer', reason: 'Risk Floor High: a migration', ...over,
});

test('formatGateCheck: a check that never fails, a short title, the result hidden in the summary', () => {
  const check = formatGateCheck(gate());
  assert.deepEqual([check.name, check.conclusion, check.title], ['Risk Gate', 'success', "High (shadow): needs another engineer's approval"]);
  const [first, ...rest] = check.summary.split('\n');
  assert.equal(first, 'Risk Floor High: a migration');
  assert.deepEqual([rest[0], rest.at(-1)], ['<!-- risk-gate', '-->']);
  assert.doesNotMatch(JSON.stringify(check), /generated|co-authored|🤖/i);
});

test('formatGateCheck: the title says what the pull request waits for', () => {
  const title = over => formatGateCheck(gate(over)).title;
  const none = { tier: null, ratingTier: null, floorTier: 'low' };
  assert.equal(title({ ...none, waitingFor: 'rating' }), 'Waiting for a Risk Rating (shadow)');
  assert.equal(title({ ...none, mode: 'live', waitingFor: 'rating' }), 'Waiting for a Risk Rating');
  assert.equal(title({ mode: 'live', tier: 'low', ratingTier: 'low', floorTier: 'low', approve: true, waitingFor: null }), 'Low: approved by the Risk Bot');
  assert.equal(title({ tier: 'low', ratingTier: 'low', floorTier: 'low', waitingFor: null }), 'Low (shadow): would be approved');
  assert.equal(title({ mode: 'live', tier: 'medium', ratingTier: 'medium', floorTier: 'low', waitingFor: 'acceptance' }), "Medium: waiting for the Writer's Risk Acceptance");
  assert.equal(title({ mode: 'live', waitingFor: 'reviewer' }), "High: needs another engineer's approval");
  assert.equal(title({ mode: 'off', waitingFor: null }), 'Risk Gate off');
});

test('parseGateCheck reads back exactly what formatGateCheck wrote', () => {
  for (const g of [
    gate(),
    gate({ mode: 'live', tier: 'low', ratingTier: 'low', floorTier: 'low', approve: true, waitingFor: null }),
    gate({ mode: 'live', tier: 'medium', ratingTier: 'low', floorTier: 'medium', approve: true, waitingFor: null }),
    gate({ tier: null, ratingTier: null, floorTier: null, patchId: null, waitingFor: 'rating', reason: 'No Risk Rating for this head' }),
    gate({ reason: 'a --> b <!-- risk-gate', patchId: 'd'.repeat(64) }),
  ]) {
    const { summary } = formatGateCheck(g);
    assert.deepEqual(parseGateCheck(summary), g);
    assert.deepEqual(parseGateCheck(summary.replaceAll('\n', '\r\n')), g, 'CRLF');
  }
});

test('parseGateCheck rejects summaries without exactly one well-formed result', () => {
  const block = json => `x\n<!-- risk-gate\n${json}\n-->`;
  const bad = [
    undefined, '', 'Risk Gate',
    formatRating(rating()), // a Risk Rating is not a Gate result
    block('{not json'),
    formatGateCheck(gate()).summary + '\n' + formatGateCheck(gate()).summary,
    ...[
      { version: 2 }, { extra: 1 }, { mode: 'on' }, { tier: 'severe' }, { approve: 'yes' }, { waitingFor: 'qa' }, { reason: '' },
      { reason: 'two\nlines' }, { headSha: null }, { patchId: 'abc' },
      { tier: 'medium', ratingTier: 'medium', floorTier: 'high' }, // below the Risk Floor
      { tier: 'low', ratingTier: 'medium', floorTier: 'low' }, // below the Risk Rating
      { mode: 'shadow', tier: 'low', ratingTier: 'low', floorTier: 'low', approve: true, waitingFor: null }, // shadow never approves
      { mode: 'live', approve: true, waitingFor: null }, // the Risk Bot never approves High
      { mode: 'live', tier: 'medium', ratingTier: 'medium', floorTier: 'low', approve: true, waitingFor: 'acceptance' },
      { mode: 'live', tier: null, ratingTier: null, approve: true, waitingFor: null },
    ].map(over => block(JSON.stringify(gate(over)))),
  ];
  for (const summary of bad) assert.equal(parseGateCheck(summary), null, String(summary));
});

test('formatGateCheck refuses an invalid result instead of writing one the dashboard would reject', () => {
  assert.throws(() => formatGateCheck(gate({ mode: 'shadow', tier: 'low', ratingTier: 'low', floorTier: 'low', approve: true, waitingFor: null })));
  assert.throws(() => formatGateCheck({ mode: 'live' }));
});
