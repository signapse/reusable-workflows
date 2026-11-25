# Risk Check regression fixtures

The 50 pull requests used to calibrate the Risk Check (SIG-3075, SIG-3076).

This repo is public, so only what the replay needs is kept: repo, PR number, tiers, Change kinds and systems. Titles, links, authors, file paths and the reasons behind each tier are left out, and every finding's file, why and check read `redacted`.

- `reference-labels.jsonl`: the reference tier for each PR, from an independent Opus labeller plus the 14-day after-merge check. A person ruled on the two PRs the Risk Check rated too low (both High).
- `answers-*.jsonl`: the Risk Check's saved answers (model tier, `certain`, Change kinds, findings) and the floor and systems for each PR, from Rubric v1, v1.1, v1.2 and v1.3. Replaying them through `decide` needs no Claude run; the newest answer for a PR wins.

- `golden.json`: each PR's Rubric tier and final tier at the last deliberate update, as a "no lower than" table. Raises pass; any lowering fails CI. Rewrite it only on purpose: `RISK_GOLDEN=update node --test test/regression.test.js` in `risk/`, with the reason in the PR.

The regression rules (`../regression.test.js`): no PR whose reference tier is High may come out lower, and no PR may rate lower than `golden.json`. Rubric rows no PR exercises alone are pinned in `../floor.test.js`.
