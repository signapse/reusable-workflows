# Release train: Release Candidate selection

`.github/workflows/release-train.yml` with `selection_mode: qa-passed` picks the
**Release Candidate**: the newest build on `main` whose tickets all carry the
`QA Passed` label (ADR 0001). It replaces the "Ready for Prod" gate and the
Tuesday/Thursday cron. Re-tagging and deploying the Release Candidate come in
later tickets (SIG-2764 onwards); for now the train selects and reports.

## How the Release Candidate is chosen

1. Find the last Promotion: the nearest tag matching `release_tag_pattern`
   (bare or `v`-prefixed semver by default) on `main`'s first-parent history.
   A tag on a merged side branch does not count.
2. Walk `main`'s first-parent commits since that tag, oldest first.
3. Read each commit's tickets: `SIG-<n>` refs in the commits it brought in
   (a merge commit includes its branch) plus the title and head branch of its
   merged PR. A ref must end at a non-alphanumeric character, so `SIG-12abc`
   is not a ticket. PR bodies are ignored, because they often mention related
   tickets.
4. Stop at the first commit with a ticket that is in the `QA Failed` column,
   lacks the `QA Passed` label, or is missing from Linear. If Linear fails or
   returns errors or incomplete data, the run fails; it never selects past a
   ticket it could not read. Nothing at or past
   that commit can be selected; the summary names it under **Blocked by**.
5. Commits with no ticket (Dependabot, chores) never block. They ride along
   and are listed as untracked.
6. A commit is a **build** when the caller's `main-push.yml` has a successful
   run for it on `main`. Its image tag is `main-<run_number>-<sha>`, the tag
   main-push gives every service image. The Release Candidate is the last
   build before the walk stopped.

Selection reads git, Linear and GitHub afresh each run and ignores which
ticket triggered it. So the hourly run picks the same build as the
label-triggered run did, and picks up a QA Passed event that was missed. If
nothing selectable has landed since the last Promotion, the outcome is `none`.
If the Release Candidate already carries a release tag, the outcome is
`already_promoted`. Later stages should do nothing in either case.

### Why a successful main-push run, not an ECR lookup

- The image tag contains main-push's `run_number`. The run gives it directly.
  ECR would mean listing every image and matching on the sha suffix.
- A successful run means every service image was pushed and, once SIG-2759
  lands, dev smoke passed. A tag in ECR only proves that one image got pushed;
  a build that failed its scan or smoke after the push would look selectable.
- The train needs no AWS credentials. Reading runs only needs `actions: read`
  on the repo's own `GITHUB_TOKEN`.

## Outputs

| Output | Example | Meaning |
|---|---|---|
| `outcome` | `selected` | `selected`, `already_promoted` or `none` |
| `rc_sha` | `4f1c…` | Release Candidate commit, empty when none |
| `rc_image_tag` | `main-212-4f1c…` | Image tag to re-tag (no rebuild) |
| `rc_tickets` | `SIG-1,SIG-2` | Tickets in the Release Candidate (signapse-e2e `tickets` format) |
| `untracked_commits` | `[{"sha":"…","subject":"chore(deps): …"}]` | Ticketless commits riding along |
| `blocked_by` | `SIG-3` | Ticket that stopped the line, empty when none |
| `selection` | JSON | Everything above plus every walked commit, its tickets and build, and the blocking commit (`blocked_by.sha`) |

The job summary shows the same data with links.

## Caller template (`.github/workflows/release-train.yml` in the product repo)

The event router (SIG-2758) dispatches this file with `ticket` and
`trigger_id` when `QA Passed` is applied. Before dispatching, it looks for a
run whose title contains the `trigger_id`, so `run-name` must include it.

That check and the dispatch are not atomic, so the router can occasionally
dispatch the same delivery twice. The per-repo `concurrency` group makes the
two runs take turns, and selection is stateless, so the second run selects the
same build (or reports `already_promoted` once a later stage tags it). Stages
added after selection (SIG-2764 onwards) must stay safe to repeat for the
same `rc_sha`: check whether the tag or deploy already exists before acting.

```yaml
name: Release Train
run-name: Release train ${{ inputs.ticket || github.event_name }} ${{ inputs.trigger_id }}

on:
  workflow_dispatch:
    inputs:
      ticket:
        description: 'Ticket whose QA Passed label triggered the run (e.g. SIG-123)'
        required: false
        type: string
      trigger_id:
        description: 'Linear webhook delivery id (event router idempotency key)'
        required: false
        type: string
  schedule:
    - cron: '23 * * * *'   # hourly backstop for missed QA Passed events

# One Promotion per repo at a time. A newer queued run replaces an older queued
# one, which is safe: every run re-reads everything and selects the same build.
concurrency:
  group: release-train-${{ github.repository }}
  cancel-in-progress: false

permissions:
  contents: write        # tags for the Promotion (SIG-2764)
  pull-requests: read    # PR title and branch per commit
  checks: read
  actions: read          # main-push runs: which commits are builds

jobs:
  train:
    uses: signapse/reusable-workflows/.github/workflows/release-train.yml@main
    with:
      selection_mode: qa-passed
      ticket: ${{ inputs.ticket }}
      trigger_id: ${{ inputs.trigger_id }}
      # build_workflow: main-push.yml   # if the build workflow has another file name
    secrets:
      LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}
```

Optional inputs: `qa_passed_label`, `qa_failed_state`, `build_workflow`,
`release_branch`, `release_tag_pattern`, `linear_team_key`. The Linear defaults
match the board after SIG-2747.

### Note for stages that dispatch other workflows (SIG-2765)

GitHub keeps at most one *pending* run per concurrency group. When a newer run
queues behind a running one, the older pending run is cancelled. This repo's
train is unaffected, because the run that survives re-selects from scratch.
But `terraform-deploy.yml` in signapse-core-terraform is serialised per
product and environment, so a run the train dispatched can conclude
`cancelled` without ever starting. Treat `cancelled` as "superseded, not
failed". Find the run that replaced it (or dispatch again) and wait for its
verdict. Do not report a Terraform failure or block the Promotion on it.

## Prerequisites for switching a repo

- The build workflow tags images `main-<run_number>-<sha>`, as the reusable
  `main-push.yml` does, and its file name is `build_workflow`.
- The image is environment-agnostic: config comes at runtime, not baked in at
  build time. Later stages re-tag the selected image for staging and prod with
  no rebuild, so a dev-configured image would ship dev config.
- A release tag on `main` to start from. Seed one with
  `git tag 0.0.0 <sha> && git push origin 0.0.0` if there is none.

Repos that do not meet these yet stay on `ready-for-prod`:

- **website-translation-portal:** its main image bakes in dev settings, and
  prod uses a separate build.
- **website-translation-platform-api:** it deploys a Lambda ZIP through
  `deploy-dev.yml` and has no image to re-tag. It needs a Lambda-aware
  Release Candidate contract first.

## Migrating a caller

- **No change needed to keep the old behaviour.** `selection_mode` defaults to
  `ready-for-prod`, which is the existing train: "Ready for Prod" gate, draft
  release and Slack cut button. SIG-2773 removes it once the pilot cuts over.
- To switch, check the prerequisites above, then replace the caller's
  `release-train.yml` with the template. Drop the Tue/Thu cron and the
  `release: published` trigger; in `qa-passed` mode a release event runs
  nothing. Add `actions: read`. `SLACK_BOT_TOKEN` is no longer needed.
