---
status: proposed
date: 2026-11-23
deciders: Alexandru Balau
---

# Who authorises a merge depends on its Risk tier, not on a universal peer review

Pull requests can wait days for a human approval, and the rule is the same for every change: one approval, whether the change fixes a typo or touches billing. Review effort isn't matched to what a change could break.

We replace "one approval from anyone or any bot" with authorisation by Risk tier. A Standard change (Low) is pre-authorised by the procedure: the Risk Bot approves it and it auto-merges once CI is green. A Writer-authorised change (Medium) merges once the Writer resolves every Risk Comment. A Significant change (High) needs another engineer, who reads only the Risk Comments. The Risk Check's summary is the recorded impact assessment ISO 27001 A.8.32 asks for. Tiering decides merging to `main` only; production still moves through the delivery pipeline (ADR 0001–0004).

## Considered Options

- **Keep universal peer review and chase reviewers** (the PR nudger plan, Oct 2026): doesn't remove the wait.
- **Medium also needs a second engineer**: kept as the fallback if the ISO auditor rejects the Writer authorising their own Medium change.

## Consequences

- Only humans and the Risk Bot may approve. CodeRabbit's approvals are switched off in each repo the day the Risk Bot goes live there; it keeps commenting.
- CI becomes a required status check, starting with the pilot repos, so nothing auto-merges red.
- The admin "always" bypass is removed once the pilot shows Low changes merge quickly, replaced by the Emergency merge procedure.
- The change-management procedure in Vanta moves to v3 before any auto-merge goes live.
- Pilot repos: sign-stream-platform, sign-stream-platform-api, sign-stream-api, website-translation-plugin, sign-stream-vc-portal and teams-media-bot. Shadow mode first.
