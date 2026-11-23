// A pull request's diff and patch-id, from git alone. Never the GitHub API: it refuses diffs over 20,000 lines.
// diff(checkout, base, head) -> { patchId, files: [{ path, status, patch }], text }
//   The diff is merge-base(base, head)..head, so main moving on doesn't change it.
//   patchId is `git patch-id --stable` of that diff: a rebase that leaves the changes the same keeps it (and with it a
//   Risk Acceptance); any new change gives a new one. null when the diff is empty.
//   status is git's letter: A added, M modified, D deleted, T type changed (renames show as D + A).
//   patch is the file's part of text, for floor().
import { execFileSync } from 'node:child_process';

// Each flag pins something a user's git config could change, so the Work Dashboard and the Risk Gate get the same
// text and patch-id. --full-index: binary changes are hashed by their index line, which must not be abbreviated.
// --no-renames: the Risk Floor sees every line of a moved file, and no rename-limit setting can change the result.
const DIFF = ['--no-color', '--no-ext-diff', '--no-textconv', '--no-relative', '--no-renames', '--full-index',
  '--src-prefix=a/', '--dst-prefix=b/', '--unified=3', '--diff-algorithm=myers', '--indent-heuristic', '--submodule=short'];

const git = (checkout, args, input) => execFileSync('git', ['-C', checkout, ...args], { input, encoding: 'utf8', maxBuffer: 1 << 30, stdio: 'pipe' });

export function diff(checkout, base, head) {
  const mergeBase = git(checkout, ['merge-base', base, head]).trim();
  const text = git(checkout, ['diff', ...DIFF, mergeBase, head]);
  const names = git(checkout, ['diff', '--name-status', '-z', '--no-renames', '--no-relative', mergeBase, head]).split('\0').filter(Boolean);
  // Each file's patch, matched by position rather than by parsing the quoted paths in the headers: git prints files
  // in the same order in both, and splits a type change (file <-> symlink or submodule) into a delete and an add.
  const chunks = text.split(/^(?=diff --git )/m).filter(Boolean);
  const files = [];
  let at = 0;
  for (let i = 0; i < names.length; i += 2) files.push({ path: names[i + 1], status: names[i], patch: chunks.slice(at, (at += names[i] === 'T' ? 2 : 1)).join('') });
  if (at !== chunks.length) throw new Error(`diff: ${files.length} files but ${chunks.length} patches`);
  const patchId = text ? git(checkout, ['patch-id', '--stable'], text).split(' ')[0] || null : null;
  return { patchId, files, text };
}
