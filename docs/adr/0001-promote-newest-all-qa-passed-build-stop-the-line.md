# Promote the newest all-QA-Passed build; a QA Failed ticket stops the line

Promotion moves a Release Candidate, which is the newest build on dev whose tickets all carry QA Passed. It never moves individual tickets. So a ticket that hasn't passed QA, or that is in QA Failed, holds back every ticket merged after it in that repo. We chose this over cherry-picking onto release branches, which breaks trunk-based delivery and means testing something different from what dev ran. We also rejected shipping main's head behind flags, which would make QA on dev pointless.

Only the QA team takes a ticket out of QA Failed. A staging failure sends every ticket in the Release Candidate there, and a prod rollback every ticket in the Deployment, not just the culprit, because the pipeline can't reliably blame one ticket. On a rollback, a ticket already in Done stays in Done and keeps QA Passed. To stop the line staying blocked indefinitely, Prodzilla opens a revert PR for a ticket's commits once it has been in QA Failed for 24 hours.

The deploy window gates Promotion only. Rollout steps (`/rollout`, `/rollout-pause`, `/rollout-abort` in Slack) can run at any time.

## Consequences

- A slow or abandoned ticket blocks its repo. The 24-hour revert is what keeps DORA lead time bounded.
- Commits with no ticket (Dependabot, chores) never block; they ride along and are listed in the Release as untracked.
- Every migration must be backward-compatible (expand/contract), because code can reach prod and be rolled back independently of its flag.
