# Deployment and Rollout are separate events; only Feature tickets are flagged

Production Deployments need no action from QA. A Prod approver approves the prod jobs (ADR 0002), and a Feature ticket ships dark: its PostHog flag is on only for the QA Cohort, a PostHog cohort of internal test users. After reviewing in prod, the QA team starts the Rollout (10% → 50% → 100%, an hour apart, with a Sentry check before each step). The ticket then has a 24-hour Stability Window before Done.

Bug and Improvement tickets have no flag. They go live on Deployment, and if their Stability Window fails they are fixed forward. Rolling back the Deployment would also pull every other ticket in it.

We rejected flagging every ticket, because fixes, backend behaviour changes, migrations and infra changes can't sensibly be hidden behind a flag. DORA counts the Deployment, not the ticket reaching Done. That matches the standard DORA definition and makes lead time independent of when QA chooses to roll out.

## Consequences

- Two PostHog projects, SignStream Production and SignStream Dev. Prodzilla creates each flag (`sig-<n>-<slug>`) with the same key in both when a Feature ticket moves to In Progress: on for everyone in dev; in prod, on for the QA Cohort and for the `environment` property's dev and staging, and at the Rollout percentage for prod. Rollout steps, pause, abort, the Sentry check and every flag guard act on the prod flag only. Prodzilla opens a removal ticket when the ticket reaches Done, and removal acts on both projects. Project ids, config names and thresholds are in the Prodzilla event router's README.
- Flags target users (PostHog persons), not customer accounts. During a partial Rollout two users of one customer can see different behaviour.
- Sentry events carry the active flags, so the Stability Window compares flag-on with flag-off error rates. Services without Sentry tracing fall back to "no new issues tagged with the flag". A Feature ticket whose service sends no flag data is never moved to Done automatically: it stays in Rolling Out and Prodzilla asks the Releasers in the releases Slack channel to confirm.
- Each Deployment is recorded as a Linear Release and a Sentry release under one version, `<repo>@<tag>` (such as `sign-stream-api@1.4.0`), where `<tag>` is the Release Candidate's semver tag. The repo prefix is there because several repos share a product pipeline and Sentry release versions are org-wide.
- A failed Deployment raises an incident.io incident with Cause = Deployment: P3 (Minor) when the automatic rollback restored prod, P2 (Major) when it failed. A Linear Release moves to Rolled back only when prod's image is rolled back. `/rollout-abort` turns the flag off; the code stays dark-deployed, the Release is unchanged and the ticket goes back to On Prod.
- dora-metrics must be rewritten to count Deployments from prod deploy events instead of tickets reaching Done.
