---
status: proposed
date: 2026-11-23
deciders: Alexandru Balau
---

# We run our own Risk Check in the Work Dashboard, enforced by a Risk Gate with no AI in it

CodeRabbit, which we already pay for, can rate merge risk and auto-approve Low-risk pull requests. We build our own Risk Check instead, because the tiers must come from our Catalogue and Rubric. CodeRabbit only takes 3,000 characters of guidance plus path exclusions. Its scoring is also a vendor model that can change without notice, which is weak evidence for an auditor, and its comments are long where ours must be one line. There's a bias problem too: factory agents already argue with CodeRabbit in review threads, so the agent writing a change could talk its judge down.

The Risk Check runs in the Work Dashboard, as a third audit next to code-review and security-review. Each engineer runs it on their own Claude plan, for their own pull requests only, so it costs no Claude API spend. It is a separate `claude -p` process: it sees the diff and the repo but not the writing agent's reasoning, and it reads the Catalogue and Rubric from `main`.

The Writer's machine therefore produces the rating but never authorises the merge. That job belongs to the Risk Gate, a GitHub Action in this repo with no AI in it. It runs from the base branch only (`pull_request_target` and `issue_comment`), so a pull request can't edit it, and it never runs the pull request's code. It accepts only the latest Risk Rating by the pull request's author for the current head, and only if the rating's patch-id matches the diff it computes itself with the shared `risk/diff.js`. It then works out the Risk Floor with `risk/floor.js`, raises the rating's tier to that floor, and approves as the Risk Bot app. The required checks and auto-merge, not the Gate, keep the merge waiting until CI is green. The app's private key stays in GitHub secrets, so a forged "Low" can only ever pass files whose floor is Low.

## Considered Options

- **CodeRabbit's Merge Risk:** rejected for the reasons above.
- **A GitHub Action running Claude on every pull request:** about $270 a month for the pilot and $940 for the org (SIG-3071). Rejected so that we spend no money on the Claude API.
- **A subscription OAuth token inside a shared Action:** Anthropic's terms describe subscription plans as for individual use, so it can't serve a team-wide bot.
- **The dashboard approving with the app key:** rejected. The key would sit on every laptop, and nothing would enforce the Risk Floor on the server.

## Consequences

- Only pull requests made through the Work Dashboard get a Risk Check. Everyone else keeps human review until they move to the dashboard.
- The check runs once per pull request, after the other two audits pass and before the PR is marked ready, and runs again only if the code changes. It uses Sonnet, and Opus only when the Risk Floor is Tier 1.
- If the Writer's plan hits its usage limit, no rating gets posted and the pull request waits for a human. That is the safe failure.
- Each Risk Rating records the model and a fingerprint of the prompt, so an auditor or the monthly sample can check how it was made.
- **We accept this risk:** the Writer's machine produces the rating, so a Writer could post a fake "Low" by hand. It can only pass files whose Risk Floor is Low. Its record gives it away, because it has no matching fingerprint and no run in the dashboard, and the monthly sample includes ratings.
- The Gate adds a "Risk Gate" check that never fails: LOW approved, MEDIUM waiting for the Writer's sign-off, HIGH needs a second engineer, or no Risk Check. Pull requests made outside the dashboard in pilot repos aren't blocked by it.
- The Risk Bot app has only `pull_requests: write`, `contents: read` and `checks: write`, and is installed only on the pilot repos (as in ADR 0005). `risk/**` and the Gate workflow need code-owner review.
