# Risk Gate

The Risk Gate (`.github/workflows/risk-gate.yml`, `gate-run.js`, `gate.js`) is the GitHub Action that enforces risk-tiered merging. It has no AI in it. On every pull request event, and on every comment by the pull request's author, it:

1. takes the author's latest Risk Rating comment, and uses it only if it is for the current head and its patch-id matches the diff the Gate computes itself (`diff.js`);
2. raises the rating's tier to the Risk Floor (`floor.js`, with `catalogue.json` and `RUBRIC.md` from `main`);
3. creates or updates a "Risk Gate" check on the head. The check never fails; its title says what the pull request is waiting for;
4. in live mode, approves as the Risk Bot: Low at once, Medium once the author's latest `/accept-risk <patch-id>` names the current patch-id, High never;
5. on any run that doesn't approve, in any mode, dismisses every approval the Risk Bot still has standing on the pull request. It matches the review's author against the App's bot login, never the review text. That run might be a higher Risk Rating for the same head (the Writer's "Raise to High", or a sibling pull request raising it), a push with no new rating yet, or shadow mode.

The Gate fetches the head as git objects and diffs it. It never checks out or runs the pull request's code.

## Calling it (SIG-3112)

Add this file to a pilot repo as `.github/workflows/risk-gate.yml`:

```yaml
name: Risk Gate

# pull_request_target and issue_comment both run this file from the base branch, so a pull request can't change the
# Gate that judges it. The Gate never checks out or runs the pull request's code.
on:
  pull_request_target:
    types: [opened, reopened, synchronize, ready_for_review]
  issue_comment:
    types: [created]

permissions:
  contents: read

jobs:
  risk-gate:
    uses: signapse/reusable-workflows/.github/workflows/risk-gate.yml@main
    with:
      mode: ${{ vars.RISK_GATE_MODE || 'off' }}
    secrets:
      RISK_BOT_APP_ID: ${{ secrets.RISK_BOT_APP_ID }}
      RISK_BOT_PRIVATE_KEY: ${{ secrets.RISK_BOT_PRIVATE_KEY }}
```

Then set things up in this order:

- The Risk Bot App (SIG-3106) is installed on the repo with `checks: write` and `pull_requests: write`, and its ID and private key are set as the `RISK_BOT_APP_ID` and `RISK_BOT_PRIVATE_KEY` secrets.
- The `RISK_GATE_MODE` repo variable is `off` (the default when unset: nothing runs), `shadow` (the check is posted, nothing is approved) or `live`.
- Nothing else dismisses the Risk Bot's approvals for it. The org ruleset keeps approvals after a push (`dismiss_stale_reviews_on_push: false`), and a higher Risk Rating comes with no push at all, so the Gate withdraws its own approval. If a ruleset or branch protection limits who may dismiss reviews, the Risk Bot must be on that list.
- An old approval stands only until the Gate's run for the new event finishes, usually under a minute. After a push, the required checks normally take longer than that. After a higher rating with no push, CI is already green, so auto-merge could merge in that minute.
- To stop the Gate, set the mode to `shadow` first. Shadow withdraws any approval still standing. `off` runs nothing, so it leaves standing approvals in place.
- "Risk Gate" is not a required check. Pull requests made outside the Work Dashboard get no Risk Rating, and they keep human review.
