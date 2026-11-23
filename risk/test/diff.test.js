import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { diff } from '../diff.js';

// A throwaway repo, set up with no user or system git config (no signing, no hooks).
const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.com', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.com' };
function repo(t) {
  const dir = mkdtempSync(join(tmpdir(), 'risk-diff-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', ['-C', dir, ...args], { env, encoding: 'utf8', stdio: 'pipe' }).trim();
  const commit = (files, msg) => {
    for (const [path, body] of Object.entries(files)) writeFileSync(join(dir, path), body);
    git('add', '-A');
    git('commit', '-qm', msg);
    return git('rev-parse', 'HEAD');
  };
  git('init', '-q', '-b', 'main');
  commit({ 'app.js': 'one\ntwo\nthree\n', 'other.js': 'a\n', 'logo.bin': Buffer.from([0, 1, 2]) }, 'base');
  return { dir, git, commit };
}

test('diff: files and text from merge-base to head, with a patch-id', t => {
  const { dir, git, commit } = repo(t);
  git('checkout', '-qb', 'feature');
  commit({ 'app.js': 'one\nTWO\nthree\n', 'new.js': 'x\n' }, 'change');
  const d = diff(dir, 'main', 'feature');
  assert.deepEqual(d.files, [{ path: 'app.js', status: 'M' }, { path: 'new.js', status: 'A' }]);
  assert.match(d.text, /^diff --git a\/app\.js b\/app\.js/m);
  assert.match(d.text, /^\+TWO$/m);
  assert.match(d.patchId, /^[0-9a-f]{40}$/);
});

test('diff: the same patch-id after main moves on and after a rebase that keeps the changes', t => {
  const { dir, git, commit } = repo(t);
  git('checkout', '-qb', 'feature');
  commit({ 'app.js': 'one\nTWO\nthree\n' }, 'change');
  const before = diff(dir, 'main', 'feature').patchId;
  git('checkout', '-q', 'main');
  commit({ 'other.js': 'b\n' }, 'main moves on');
  assert.equal(diff(dir, 'main', 'feature').patchId, before, 'merge-base, not main');
  git('checkout', '-q', 'feature');
  const oldHead = git('rev-parse', 'HEAD');
  git('rebase', '-q', 'main');
  assert.notEqual(git('rev-parse', 'HEAD'), oldHead);
  assert.equal(diff(dir, 'main', 'feature').patchId, before, 'rebase keeps the patch-id');
});

test('diff: a new patch-id when the changes change, binary files included', t => {
  const { dir, git, commit } = repo(t);
  git('checkout', '-qb', 'a');
  const binary1 = diff(dir, 'main', commit({ 'logo.bin': Buffer.from([0, 1, 3]) }, 'binary')).patchId;
  const text1 = diff(dir, 'main', commit({ 'app.js': 'one\nTWO\nthree\n' }, 'text')).patchId;
  const text2 = diff(dir, 'main', commit({ 'app.js': 'one\nTWO\nthree\nfour\n' }, 'more')).patchId;
  git('checkout', '-qb', 'b', 'main');
  const binary2 = diff(dir, 'main', commit({ 'logo.bin': Buffer.from([0, 1, 4]) }, 'other binary')).patchId;
  assert.equal(new Set([binary1, text1, text2, binary2]).size, 4);
});

test('diff: an empty diff has no patch-id', t => {
  const { dir } = repo(t);
  assert.deepEqual(diff(dir, 'main', 'main'), { patchId: null, files: [], text: '' });
});
