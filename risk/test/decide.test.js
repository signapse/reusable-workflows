import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decide } from '../decide.js';
import { KINDS } from '../floor.js';

const none = Object.fromEntries(KINDS.map(k => [k, false]));
const finding = (over = {}) => ({ file: 'src/a.go', line: 3, system: 'app', kind: 'live-behaviour', why: 'Changes retries.', check: 'Confirm retries stop', ...over });
const answer = (over = {}) => ({ tier: 'medium', certain: true, kinds: { ...none, 'live-behaviour': true }, findings: [finding()], ...over });
const floorOf = (tier = 'low', systemTier = 3) => ({ tier, systems: ['app'], systemTier, flags: [] });
const ctx = (over = {}) => ({ floor: floorOf(), ...over });

test('rejects answers that break the format', () => {
  const bad = [
    null, 'high', [],
    answer({ tier: 'severe' }),
    answer({ certain: 'yes' }),
    answer({ kinds: { 'live-behaviour': true } }),
    answer({ kinds: { ...none, 'live-behavior': true } }),
    answer({ findings: 'none' }),
    answer({ findings: [finding({ line: 0 })] }),
    answer({ findings: [finding({ line: '12' })] }),
    answer({ findings: [finding({ kind: 'security' })] }),
    answer({ findings: [finding({ check: ' ' })] }),
    answer({ findings: [] }), // Medium needs a finding
  ];
  for (const a of bad) {
    const r = decide(a, ctx());
    assert.equal(r.ok, false, JSON.stringify(a));
    assert.equal(typeof r.error, 'string');
  }
});

test('a certain answer keeps its tier; an unsure one goes up one step', () => {
  assert.equal(decide(answer({ certain: true }), ctx()).tier, 'medium');
  assert.equal(decide(answer({ certain: false }), ctx()).tier, 'high');
  assert.equal(decide(answer({ tier: 'low', certain: false, kinds: none, findings: [] }), ctx()).tier, 'medium');
  assert.equal(decide(answer({ tier: 'high', certain: false }), ctx()).tier, 'high');
});

test('the final tier is the highest of the Risk Check, the Rubric and the Risk Floor', () => {
  const low = answer({ tier: 'low', kinds: { ...none, 'live-behaviour': true }, findings: [] });
  const byRubric = decide(low, ctx({ floor: floorOf('low', 1) })); // live-behaviour on Tier 1 is High
  assert.deepEqual([byRubric.tier, byRubric.modelTier, byRubric.rubricTier, byRubric.floorTier], ['high', 'low', 'high', 'low']);
  const byFloor = decide(answer({ tier: 'low', kinds: none, findings: [] }), ctx({ floor: floorOf('high') }));
  assert.equal(byFloor.tier, 'high');
  assert.match(byFloor.summary, /tier from the Risk Floor/);
});

test('Low gets a one-line summary and no Risk Comments', () => {
  const r = decide(answer({ tier: 'low', kinds: { ...none, 'ui-copy': true }, findings: [finding()] }), ctx());
  assert.deepEqual([r.ok, r.tier, r.findings], [true, 'low', []]);
  assert.equal(r.summary, 'ui-copy on app (Tier 3)');
});

test('keeps at most five findings, most severe first as listed', () => {
  const findings = Array.from({ length: 7 }, (_, i) => finding({ line: i + 1 }));
  const r = decide(answer({ findings }), ctx());
  assert.deepEqual(r.findings.map(f => f.line), [1, 2, 3, 4, 5]);
});

test('drops findings on tests and docs files', () => {
  const findings = [finding({ file: 'src/a_test.go' }), finding({ file: 'docs/api.md' }), finding({ file: 'src/a.go' })];
  assert.deepEqual(decide(answer({ findings }), ctx()).findings.map(f => f.file), ['src/a.go']);
});

test('trims why to 12 words and check to 10, marking the cut', () => {
  const why = 'one two three four five six seven eight nine ten eleven twelve thirteen';
  const check = 'a b c d e f g h i j k';
  const [f] = decide(answer({ findings: [finding({ why, check })] }), ctx()).findings;
  assert.equal(f.why, 'one two three four five six seven eight nine ten eleven twelve…');
  assert.equal(f.check, 'a b c d e f g h i j…');
  const [short] = decide(answer({ findings: [finding({ why: 'Ten words\nor  fewer.', check: 'Fine' })] }), ctx()).findings;
  assert.deepEqual([short.why, short.check], ['Ten words or fewer.', 'Fine']);
});

test('moves a finding on a punctuation-only line to the nearest code line', () => {
  const lines = ['func f() {', '  retry(3)', '}', ');', '', 'next()'];
  const at = line => decide(answer({ findings: [finding({ line })] }), ctx({ readLines: p => (p === 'src/a.go' ? lines : undefined) })).findings[0].line;
  assert.equal(at(2), 2); // already code
  assert.equal(at(3), 2); // `}` -> the line above
  assert.equal(at(4), 2); // `);` -> line 2 and line 6 are both two away: above wins the tie
  assert.equal(at(5), 6); // blank: down 1 beats up 3
  assert.equal(at(40), 6); // past the end -> the last code line
});

test('leaves the line alone when the file cannot be read', () => {
  const r = decide(answer({ findings: [finding({ line: 9 })] }), ctx({ readLines: () => undefined }));
  assert.equal(r.findings[0].line, 9);
  assert.equal(decide(answer({ findings: [finding({ line: 9 })] }), ctx()).findings[0].line, 9);
});

test('keeps only the finding fields the Risk Comment needs', () => {
  const [f] = decide(answer({ findings: [finding({ note: 'extra' })] }), ctx()).findings;
  assert.deepEqual(Object.keys(f), ['file', 'line', 'system', 'kind', 'why', 'check']);
});

test('the summary names the kinds, systems and what set the tier', () => {
  const r = decide(answer({ certain: false }), ctx({ floor: floorOf('low', 2) }));
  assert.equal(r.summary, 'live-behaviour on app (Tier 2); tier from the Risk Check (Risk Check unsure)');
  assert.ok(!r.summary.includes('\n'));
});

test('throws when the caller passes no floor, rather than rating without one', () => {
  assert.throws(() => decide(answer(), {}));
});
