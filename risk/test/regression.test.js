// Replays the Risk Check's saved answers for the 50 calibration PRs through decide, with today's Catalogue and Rubric.
// No PR whose reference tier is High may come out lower. See fixtures/README.md.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { decide } from '../decide.js';

const fixture = name => new URL(`fixtures/${name}`, import.meta.url);
const jsonl = name => readFileSync(fixture(name), 'utf8').trim().split('\n').map(l => JSON.parse(l));
const catalogue = JSON.parse(readFileSync(new URL('../catalogue.json', import.meta.url), 'utf8'));

const labels = jsonl('reference-labels.jsonl');
// answers-v1-…, answers-v11-…, answers-v12-…: a later Rubric version's answer for a PR replaces an earlier one.
const version = f => Number(f.match(/^answers-v(\d+)/)[1]);
const files = readdirSync(fixture('')).filter(f => /^answers-v\d+.*\.jsonl$/.test(f)).sort((a, b) => version(a) - version(b));
const newest = new Map(files.flatMap(f => jsonl(f).map(a => [`${a.repo}#${a.number}`, a])));

// Each saved line holds the model's answer (model = its tier) and the Risk Floor worked out then. The floor tier stands
// (the diffs aren't kept); the system tier comes from today's Catalogue.
const systemTier = ids => (ids.length ? Math.min(...ids.map(id => catalogue.systems.find(s => s.id === id)?.tier ?? 2)) : 3);
const replay = saved => decide(
  { tier: saved.model, certain: saved.certain, kinds: saved.kinds, findings: saved.findings },
  { floor: { tier: saved.floor, systems: saved.systems, systemTier: systemTier(saved.systems) } },
);

test('every calibration PR has a saved answer that is still a valid answer', () => {
  assert.equal(labels.length, 50);
  for (const { repo, number } of labels) {
    const saved = newest.get(`${repo}#${number}`);
    assert.ok(saved, `${repo}#${number} has no saved answer`);
    const r = replay(saved);
    assert.ok(r.ok, `${repo}#${number}: ${r.error}`);
  }
});

test('no PR whose reference tier is High comes out lower', () => {
  const high = labels.filter(l => l.label === 'high');
  assert.ok(high.length > 0);
  const lower = high
    .map(({ repo, number }) => ({ pr: `${repo}#${number}`, r: replay(newest.get(`${repo}#${number}`)) }))
    .filter(({ r }) => r.ok && r.tier !== 'high')
    .map(({ pr, r }) => `${pr} came out ${r.tier} (Risk Check ${r.modelTier}${r.certain ? '' : ', unsure'}, Rubric ${r.rubricTier}, Risk Floor ${r.floorTier})`);
  assert.deepEqual(lower, []);
});
