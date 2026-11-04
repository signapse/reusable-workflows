# Release train: Release Candidate selection

`.github/workflows/release-train.yml` with `selection_mode: qa-passed` picks the
**Release Candidate**: the newest build on `main` whose tickets all carry the
`QA Passed` label (ADR 0001). It replaces the "Ready for Prod" gate and the
Tuesday/Thursday cron. Re-tagging and deploying the Release Candidate come in
later tickets (SIG-2764 onwards); for now the train selects and reports.

## How the Release Candidate is chosen

1. Find where prod is: the release tag prod runs (`selection-base.sh`, which
   reads each `prod_services` entry's prod file in signapse-core-k8s with
   `prod-tags.sh`). With several services on different tags, the oldest. After
   a rollback, prod runs the previous tag again, so that is the base.
   `selection_base` overrides it, only for the first Deployment through the
   train, when prod runs a tag this repo does not have.
2. Walk `main`'s first-parent commits since that tag, oldest first. Release
   tags already promoted to staging are inside the walk and are checked again
   on every run.
3. Read each commit's tickets: `SIG-<n>` refs in the commits it brought in
   (a merge commit includes its branch) plus the title and head branch of its
   merged PR. A ref must end at a non-alphanumeric character, so `SIG-12abc`
   is not a ticket. PR bodies are ignored, because they often mention related
   tickets.
4. Stop at the first commit with a ticket that is in the `QA Failed` column,
   lacks the `QA Passed` label, or is missing from Linear. Missing means
   Linear answered `issue: null` (how it reports an unknown identifier, with
   or without GraphQL errors): that ticket blocks, and the run succeeds. A
   failed call, an unparsable reply, GraphQL errors next to issue data, or an
   issue lacking its state or labels fail the run instead; it never selects
   past a ticket it could not read. Nothing at or past
   that commit can be selected; the summary names it under **Blocked by**.
5. Commits with no ticket (Dependabot, chores) never block. They ride along
   and are listed as untracked.
6. **Reverts** (ADR 0001's 24 h revert, SIG-2766), recognised by git's
   `This reverts commit <sha>` line (`lib/revert.sh`). The line alone is not
   enough: the commit must undo the commits it names and do nothing else
   (its whole tree equals its parent with each named commit reverted, newest
   first; a squashed revert PR naming several commits works). Otherwise it is
   a normal commit and the tickets it names, and its own, are checked.
   - A commit reverted later in the walk does not block, and its tickets are
     not in the candidate. It is listed under **Reverted**. Builds between it
     and its revert are not selectable: they still contain its code.
   - A revert commit, or a merged revert PR whose commits are all reverts,
     never blocks, whatever ticket its message, PR title or branch names
     (`prodzilla/revert-SIG-n`). It rides along as untracked.
   - A revert that is itself reverted (a re-land) does not count: the
     original commit and the re-land block again until QA passes the ticket.
   - A ticket with any commit that is not reverted still blocks there.
7. A commit is a **build** when the caller's `main-push.yml` has a successful
   run for it on `main`. Its image tag is `main-<run_number>-<sha>`, the tag
   main-push gives every service image. The Release Candidate is the last
   build before the walk stopped.

Why walk from prod and not from the last Promotion tag: a tag that failed
staging, or that prod rolled back from, leaves its tickets in `QA Failed`
behind that tag. Walking from it would let the next Release Candidate carry
their code to staging and prod while they are still failed (ADR 0001: only QA
takes a ticket out of QA Failed). From prod's tag, those tickets stop the line
until QA re-passes them or their commits are reverted.

Selection reads git, Linear and GitHub afresh each run and ignores which
ticket triggered it. So the hourly run picks the same build as the
label-triggered run did, and picks up a QA Passed event that was missed. If
nothing selectable has landed since prod's tag, the outcome is `none`. If the
Release Candidate already carries a release tag (it was promoted and nothing
newer is selectable), the outcome is `already_promoted`; the promote stage
does nothing then.

`rc_tickets` are all the live tickets from prod's tag to the Release
Candidate, not only the ones new since the last Promotion. Staging tests and
prod act on that same set.

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
| `rc_tickets` | `SIG-1,SIG-2` | Every live ticket from prod's tag to the Release Candidate (signapse-e2e `tickets` format) |
| `untracked_commits` | `[{"sha":"…","subject":"chore(deps): …"}, {"sha":"…","subject":"Revert …","revert":true}]` | Commits riding along without a ticket check: ticketless commits, and revert commits (`revert: true`) even when their message, PR title or branch names a ticket |
| `blocked_by` | `SIG-3` | Ticket that stopped the line, empty when none |
| `selection_base` | `1.2.40` | Where the walk started: the release tag prod runs |
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
  contents: read
  pull-requests: read    # PR title and branch per commit
  actions: read          # main-push runs: which commits are builds

jobs:
  train:
    uses: signapse/reusable-workflows/.github/workflows/release-train.yml@main
    with:
      selection_mode: qa-passed
      ticket: ${{ inputs.ticket }}
      trigger_id: ${{ inputs.trigger_id }}
      # build_workflow: main-push.yml   # if the build workflow has another file name
      prod_services: '["signstream-api","signstream-websocket"]'   # deploy-prod.yml service names
      read_app_id: ${{ vars.PIPELINE_READ_APP_ID }}
    secrets:
      LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}
      READ_APP_PRIVATE_KEY: ${{ secrets.READ_APP_PRIVATE_KEY }}
```

`prod_services` and `read_app_id` (with secret `READ_APP_PRIVATE_KEY`) are
required unless `selection_base` is set: the walk starts at the tag prod
runs, read from `gitops_repo` with the read-only app.

Optional inputs: `qa_passed_label`, `qa_failed_state`, `build_workflow`,
`release_branch`, `release_tag_pattern`, `linear_team_key`, `gitops_repo`,
`gitops_ref`, `selection_base`. The Linear defaults
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
- Prod runs a release tag of this repo on every `prod_services` entry, or
  `selection_base` is set for the first Deployment through the train.
- The read-only pipeline app (ADR 0005) is installed on signapse-core-k8s.

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

## Revert PRs for tickets stuck in QA Failed (SIG-2766)

A QA Failed ticket stops its repo's line: no Release Candidate can form past
its commits (ADR 0001). `qa-failed-revert.yml` limits how long that lasts.
Once a ticket has been in QA Failed for `threshold_hours` (default 24),
Prodzilla opens a PR reverting the ticket's commits, so the QA Passed work
merged after it can ship while the fix is made. A person reviews and merges
the revert. It is stateless; callers run it hourly.

How it decides (details in `actions/release-train/scripts/qa-failed-revert.sh`):

- **Which tickets.** Tickets referenced by first-parent commits on
  `release_branch` since the tag prod runs (`selection-base.sh`, the same
  base as Release Candidate selection; `selection_base` overrides it), found
  the way selection finds them (commit messages, PR title, PR branch). A
  ticket that failed staging sits in an already-tagged build, so walking only
  from the last Promotion tag would never revert it. Only
  tickets *currently* in QA Failed count. A ticket that QA re-passes leaves
  the column and is never reverted.
- **When.** The clock starts at the newest Linear history entry that moved
  the ticket into QA Failed, so re-entering the column restarts it.
- **What.** The ticket's commits since the tag, newest first. Merge commits
  are reverted against their first parent. Revert commits are never
  reverted. A commit that a live revert since the tag already undoes ("This
  reverts commit …", `lib/revert.sh`; a revert that was itself reverted does
  not count) or whose revert changes nothing is skipped and listed. Once the
  revert PR merges, selection treats the reverted commits as gone and the
  revert itself as untracked, so the line moves again.
  If every commit is already reverted, no PR is opened.
- **PR.** Branch `prodzilla/revert-<ticket>`, title
  `Revert <ticket>: <ticket title>`. The body explains why, lists the
  reverted and skipped commits, and warns when a commit also carries another
  ticket. The PR link is commented on the ticket.
- **Once per ticket.** No PR is opened while an open PR from
  `prodzilla/revert-<ticket>` exists, or while that branch exists. With an open
  PR, the run still posts the PR link on the ticket if an earlier run failed
  to. If the branch
  is left without an open PR, the run summary warns; reopen the PR or delete the
  branch.
- **Conflict.** The revert stops at the conflicting commit. The newer commits
  that did revert stay on the branch (or an empty marker commit if none did).
  A **draft** PR says which commit and files conflict, lists the older
  commits not attempted, and how to finish. A
  comment goes on the ticket, and a Slack alert goes to `slack_channel` if it
  is set. The branch dedupes later runs, so each of those is sent once.
- **Failures are loud.** Linear or GitHub read errors fail the run before
  anything is opened. A failed push, PR, comment or alert fails the run after
  the other tickets are handled, and is named in the job summary.

### Caller template (`.github/workflows/qa-failed-revert.yml` in the product repo)

```yaml
name: QA Failed revert

on:
  schedule:
    - cron: '41 * * * *'   # hourly
  workflow_dispatch:        # lets QA run it on demand when testing

permissions:
  contents: read           # writes use the Prodzilla app token, minted inside

jobs:
  revert:
    uses: signapse/reusable-workflows/.github/workflows/qa-failed-revert.yml@main
    with:
      prodzilla_app_id: ${{ vars.PRODZILLA_APP_ID }}
      prod_services: '["signstream-api","signstream-websocket"]'   # as the release train
      read_app_id: ${{ vars.PIPELINE_READ_APP_ID }}
      # threshold_hours: '0.1'     # quoted string; QA testing only (6 minutes)
      # slack_channel: '#releases' # conflict alerts
    secrets:
      PRODZILLA_APP_PRIVATE_KEY: ${{ secrets.PRODZILLA_APP_PRIVATE_KEY }}
      READ_APP_PRIVATE_KEY: ${{ secrets.READ_APP_PRIVATE_KEY }}
      LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}
      # SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}   # with slack_channel
```

Optional inputs: `threshold_hours`, `slack_channel`, `qa_failed_state`,
`linear_team_key`, `release_branch`, `release_tag_pattern`, `gitops_repo`,
`gitops_ref`, `selection_base` (instead of `prod_services` and
`read_app_id`).

### Credentials

The PR must be opened by the Prodzilla GitHub App. PRs opened with
`GITHUB_TOKEN` do not trigger CI (ADR 0005). The workflow mints a token for
the calling repo only, with `contents: write`, `pull_requests: write` and
`workflows: write`.
Without `prodzilla_app_id` or `PRODZILLA_APP_PRIVATE_KEY`, it fails with an
error and never falls back to `GITHUB_TOKEN`. Prerequisites:

- The Prodzilla app is installed on the repo (installation repo list, managed
  in Terraform).
- `PRODZILLA_APP_ID` (variable) and `PRODZILLA_APP_PRIVATE_KEY` (secret) are
  available to the repo.
- The app's installation grants `Workflows: write` (manual step in the app
  settings): the token asks for it so a revert that touches
  `.github/workflows/` can be pushed. Without the grant, minting the token
  fails.
