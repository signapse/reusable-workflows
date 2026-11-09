# Deployment and Rollout are separate events; only Feature tickets are flagged

Production Deployments run with no human approval. A Feature ticket ships dark: its PostHog flag is on only for the QA Cohort, a PostHog cohort of internal test users. After reviewing in prod, the QA team starts the Rollout (10% → 50% → 100%, an hour apart, with a Sentry check before each step). The ticket then has a 24-hour Stability Window before Done.

Bug and Improvement tickets have no flag. They go live on Deployment, and if their Stability Window fails they are fixed forward. Rolling back the Deployment would also pull every other ticket in it.

We rejected flagging every ticket, because fixes, backend behaviour changes, migrations and infra changes can't sensibly be hidden behind a flag. DORA counts the Deployment, not the ticket reaching Done. That matches the standard DORA definition and makes lead time independent of when QA chooses to roll out.

## Consequences

- ~~One PostHog project for all environments. Flags target an `environment` property and the account group.~~ Superseded on 2026-11-09, see below: two PostHog projects, and flags target users (PostHog persons).
- Prodzilla creates each flag (`sig-<n>-<slug>`) when a Feature ticket moves to In Progress, and opens a removal ticket when it reaches Done.
- Sentry events carry the active flags, so the Stability Window compares flag-on with flag-off error rates. Services without Sentry tracing fall back to "no new issues tagged with the flag".
- dora-metrics must be rewritten to count Deployments from prod deploy events instead of tickets reaching Done.

## Decisions 2026-11-09

- **Two PostHog projects** (Decision 10, Alex): `SignStream Production` (256388) and `SignStream Dev` (275880). Prodzilla creates each `sig-<n>-<slug>` flag with the same key in both. In the dev project it is on for everyone. In the prod project it keeps the standard template: `environment` dev or staging at 100%, the QA Cohort at 100%, `environment` prod at the Rollout percentage. Rollout steps, pause, abort, the Sentry check and every flag guard act on the prod project's flag only; removal acts on both. The `environment` property stays. Config: `posthog_project_id_prod`, `posthog_project_id_dev`, `qa_cohort_id` (a prod-project cohort).
- **Flags target users** (PostHog persons), not customer accounts (Decision 9). During a partial Rollout two users of one customer can see different behaviour.
- **Rollout and Stability Window thresholds** (Decision 5), to tune after the pilot: a Rollout step stops at 1.5x the flag-off error-rate baseline and +1 percentage point, with at least 200 transactions. An unflagged ticket's Stability Window fails on a new issue with at least 5 events or 2 users.
- **No flag data** (Decision 4): a Feature ticket whose service sends no flag data to Sentry is not moved to Done automatically. Prodzilla posts in the stability Slack channel (the releases channel the existing release pipelines post to, Decision 15), mentioning the Releasers, and asks one to confirm. The ticket stays in On Prod until then.
- **Failed Deployments raise an incident.io incident** with Cause = Deployment (Decision 3): an automatic rollback that restored prod is P3 (Minor); a failed rollback is P2 (Major).
- The deploy window gates Promotion only; Rollout steps are not window-gated (Decision 1).
- **Prod approval** (Decisions 16 and 19): prod Terraform applies and k8s `deploy-prod` run in GitHub environments whose required reviewers are the Releasers. This changes "Production Deployments run with no human approval" above: a Releaser approves the prod job, and QA still does not have to act for a Deployment to happen.
