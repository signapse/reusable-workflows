#!/usr/bin/env node
// The Risk Gate's glue, run by .github/workflows/risk-gate.yml from the calling repo's base-branch checkout (the cwd).
// Node built-ins only; every GitHub call goes through `gh api`. It never runs the pull request's code: the head is
// fetched as git objects, never checked out, and only diffed. Everything from the event and the API is untrusted and
// reaches git and gh as arguments, never through a shell.
// Env: GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, GITHUB_REPOSITORY, RISK_GATE_MODE, RISK_BOT_SLUG (the Risk Bot App's
//      slug), GH_TOKEN (the Risk Bot's installation token, read by gh).
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { diff } from './diff.js';
import { floor } from './floor.js';
import { parseRating, parseAcceptance } from './rating.js';
import { gate } from './gate.js';

const { GITHUB_EVENT_NAME: eventName, GITHUB_EVENT_PATH: eventPath, GITHUB_REPOSITORY: repo, RISK_GATE_MODE: mode, RISK_BOT_SLUG: slug } = process.env;
const SHA = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;
const run = (cmd, args, input) => execFileSync(cmd, args, { input, encoding: 'utf8', maxBuffer: 1 << 30, stdio: ['pipe', 'pipe', 'inherit'] });
const gh = (args, body) => JSON.parse(run('gh', ['api', ...args, ...(body ? ['--input', '-'] : [])], body && JSON.stringify(body)) || 'null');
const ghAll = path => gh(['--paginate', '--slurp', path]).flat();

function prNumber(event) {
  if (eventName === 'pull_request_target') return event.pull_request?.number;
  if (eventName === 'issue_comment') return event.issue?.pull_request ? event.issue.number : null;
  throw new Error(`Risk Gate: unsupported event ${eventName}`);
}

function main() {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo ?? '')) throw new Error(`Risk Gate: GITHUB_REPOSITORY is not owner/name: ${repo}`);
  if (!/^[a-z0-9-]+$/.test(slug ?? '')) throw new Error('Risk Gate: RISK_BOT_SLUG must be the Risk Bot App slug');
  const number = prNumber(JSON.parse(readFileSync(eventPath, 'utf8')));
  if (number === null) return console.log('Risk Gate: not a pull request comment, nothing to do');
  if (!Number.isInteger(number) || number < 1) throw new Error('Risk Gate: the event has no pull request number');

  // The pull request, its head and its author from the API, for both events: a run judges the PR as it is now.
  const pr = gh([`repos/${repo}/pulls/${number}`]);
  if (pr.state !== 'open') return console.log(`Risk Gate: #${number} is ${pr.state}, nothing to do`);
  const { head: { sha: headSha }, base: { sha: baseSha }, user: { login: prAuthor } } = pr;
  if (!SHA.test(headSha) || !SHA.test(baseSha)) throw new Error('Risk Gate: the pull request has no valid head or base SHA');

  // The author's latest Risk Rating and Risk Acceptance. gate() checks the author and parses them again.
  const mine = ghAll(`repos/${repo}/issues/${number}/comments`).filter(c => c.user?.login === prAuthor).map(c => ({ author: c.user.login, body: c.body }));
  const rating = mine.findLast(c => parseRating(c.body)) ?? null;
  const acceptance = mine.findLast(c => parseAcceptance(c.body)) ?? null;

  // The head as objects only: no checkout, so no hooks, filters or builds; diff() turns off external diff and textconv.
  run('git', ['fetch', '--no-tags', '--quiet', 'origin', baseSha, `refs/pull/${number}/head`]);
  const d = diff('.', baseSha, headSha);
  const catalogue = JSON.parse(readFileSync(new URL('catalogue.json', import.meta.url), 'utf8'));
  const fl = floor({ repo: repo.split('/')[1], files: d.files }, catalogue);
  const { check, approve } = gate({ rating, prAuthor, headSha, patchId: d.patchId, floor: fl, mode, acceptance });

  // The Risk Bot's own approvals, matched by its login. A run that doesn't approve withdraws them, first: a higher
  // Risk Rating for the same head comes with no push, so nothing else would dismiss them. Shadow and off too.
  const botApprovals = ghAll(`repos/${repo}/pulls/${number}/reviews`).filter(r => r.user?.login === `${slug}[bot]` && r.state === 'APPROVED');
  if (!approve) {
    for (const { id } of botApprovals) {
      if (!Number.isInteger(id)) throw new Error('Risk Gate: a review has no numeric id');
      gh(['-X', 'PUT', `repos/${repo}/pulls/${number}/reviews/${id}/dismissals`], { message: `Risk Gate: ${check?.title ?? 'off'}; approval withdrawn`, event: 'DISMISS' });
      console.log(`Risk Gate: withdrew the Risk Bot's approval (review ${id})`);
    }
  }
  if (!check) return console.log('Risk Gate: off');

  // Create or update the Risk Bot's own "Risk Gate" check on the head.
  const rulesSha = run('git', ['-C', import.meta.dirname, 'rev-parse', 'HEAD']).trim();
  const body = { name: check.name, status: 'completed', conclusion: check.conclusion, output: { title: check.title, summary: check.summary, text: `Judged with the Catalogue and Rubric at signapse/reusable-workflows@${rulesSha}.` } };
  const mineCheck = gh([`repos/${repo}/commits/${headSha}/check-runs?check_name=${encodeURIComponent(check.name)}`]).check_runs.find(c => c.app?.slug === slug);
  if (mineCheck) gh(['-X', 'PATCH', `repos/${repo}/check-runs/${mineCheck.id}`], body);
  else gh(['-X', 'POST', `repos/${repo}/check-runs`], { ...body, head_sha: headSha });
  console.log(`Risk Gate: ${check.title}`);

  // Approve the judged head (commit_id pins it), once.
  if (!approve) return;
  if (botApprovals.some(r => r.commit_id === headSha)) return console.log('Risk Gate: the Risk Bot already approved this head');
  gh(['-X', 'POST', `repos/${repo}/pulls/${number}/reviews`], { commit_id: headSha, event: 'APPROVE', body: `Risk Gate: ${check.title}` });
}

main();
