# Release train: Release Candidate selection

`.github/workflows/release-train.yml` with `selection_mode: qa-passed` picks the
**Release Candidate**: the newest build on `main` whose tickets all carry the
`QA Passed` label (ADR 0001). It replaces the "Ready for Prod" gate and the
Tuesday/Thursday cron. The `promote` job then promotes it to staging
(SIG-2764, see [Promotion to staging](#promotion-to-staging)); Terraform,
staging tests and prod come in later tickets.

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
prod act on that same set. `staged_tag` and `staged_tickets` name the newest
selectable build that already carries a release tag (and its tickets from
prod's tag): what prod deploys when a run promotes nothing new.

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
| `staged_tag` | `1.2.44` | Newest selectable build already carrying a release tag, empty when none (prod resume, SIG-2769) |
| `staged_tickets` | `SIG-1,SIG-2` | Tickets from `selection_base` to `staged_tag` |
| `selection` | JSON | Everything above plus every walked commit, its tickets and build, and the blocking commit (`blocked_by.sha`) |

The job summary shows the same data with links.

Promotion outputs (empty when the promote job did not run, i.e. `outcome` is
`none` or `already_promoted`):

| Output | Example | Meaning |
|---|---|---|
| `promoted` | `true` | Tagged, staging runs it, tickets On Staging. `false` when deferred |
| `deferred` | `false` | `true` when nothing was done: outside the deploy window, or `superseded` |
| `version` | `1.2.45` | Semver of the Promotion, no prefix |
| `release_tag` | `1.2.45` | Tag created in git and ECR (prefix follows the repo's existing tags) |
| `image_digest` | `{"signstream/http":"sha256:…"}` | ECR repository -> digest; same as the dev build's |
| `promotion_decision` | `open` | `open`, `hotfix`, `deferred`, `superseded` or `resume` |

## Promotion to staging

The `promote` job runs after `select` when `outcome` is `selected`:

1. **Plan** (`promotion-plan.sh`, read-only). Reads the tickets' Linear labels,
   checks the deploy window and picks the version:
   - **Deploy window** (`deploy-window.sh`): Monday-Thursday 09:00-16:00 and
     Friday 09:00-12:00, Europe/London time, so GMT or BST as the clocks say.
     The start is inside, the end is not (Thu 16:00 is closed). A ticket
     labelled `hotfix` (`hotfix_label`) bypasses it, but only a ticket new
     in this Promotion (in a commit after the last release tag): a label
     left on a ticket already on staging does not open the window for every
     later Promotion. SIG-2769 reuses the same script for prod.
   - **Superseded**: another Promotion tagged while this one was queued (see
     "Concurrency"); nothing is done.
   - **Version** (`promotion-version.sh`): the highest release tag in the
     repo, bumped by `version-bump.sh` (any `major` label -> major, any
     `minor` -> minor, else patch). The highest, not the nearest, because
     Flux's staging ImagePolicy deploys the highest semver tag. The new tag
     keeps the repo's prefix: bare (`1.2.45`) for every Signapse repo today,
     which some staging ImagePolicies require.
2. **Terraform gate** (SIG-2765, `actions/terraform-gate`): plans and
   applies the product's `stg` stack in signapse-core-terraform and checks
   that every ticket's merged Terraform PRs are applied in `stg`. A destroy
   or replace of a stateful resource, a failed run or an unapplied PR alerts
   Slack and fails the job here,
   before any tag. Skipped on `resume`. See [Terraform gate](#terraform-gate).
3. **Clear staging verdicts** (`ticket-labels-remove.sh`): every ticket in
   `rc_tickets` loses `Staging Passed` and `Staging Failed`. A staging
   verdict belongs to one tag; without this, a ticket that passed staging in
   an earlier tag would still look passed if this tag's staging tests never
   finished, and prod's resume mode would deploy an untested build. Runs
   after the gate and before the tag, so a Linear failure here leaves nothing
   promoted. Skipped on `resume`: the tag already exists, so any verdict is
   this tag's.
4. **Tag** (`promotion-tag.sh`): for each repository in `services`,
   `ecr-retag.sh` re-puts the Release Candidate's manifest
   (`main-<n>-<sha>`) under the release tag. No rebuild: the bytes are the
   same, and the script reads both digests back and fails if they differ. It
   never moves an existing release tag to other bytes, and a failed lookup
   (anything but "not found") stops it before any write. Then the commit gets
   the same tag in git through the GitHub API. The summary lists both digests
   per repository. Set the ECR repositories' tag mutability to `IMMUTABLE`
   (a manual step in signapse-core-terraform): on a mutable repository
   another writer could still set the tag between the script's lookup and its
   write. On an immutable one that write fails and the script reads the tag
   back instead.
5. **Wait for staging** (`staging-deploy-wait.sh`, bounded by
   `staging_deploy_timeout_minutes`): Flux image automation commits the new
   tag into each `staging_watch_paths` file in signapse-core-k8s (the
   `{"$imagepolicy": …}` setter line). Then it polls every URL in
   `staging_version_url` (newline- or comma-separated, one per service that
   has a version endpoint) until each reports the tag (or newer).
   **`staging_version_url` is required**: a Flux commit only says the tag was
   chosen, one service's version says nothing about another's rollout, and
   the old fixed
   sleep let staging tests run against the old pods. A repo without a version
   endpoint cannot switch to `qa-passed` until it has one.
6. **Tickets**: every ticket in `rc_tickets` moves to `On Staging`
   (`on_staging_state`) with the Ticket Transitioner, forward only: only from
   the columns in `on_staging_from` (default `On Dev · Ready for QA`, plus
   today's `Ready for QA`, `QA in Progress`, `Ready for Prod`). A ticket that
   is already further on (On Prod, Rolling Out) because of a follow-up commit
   stays where it is. The Ticket Transitioner never moves a ticket out of
   `QA Failed` or `Done` (ADR 0001: only QA takes a ticket out of QA Failed),
   and works on the team `linear_team_key`.

## Terraform gate

Terraform must pass before every Promotion (ADR 0002). The composite action
`actions/terraform-gate` does it in four steps, all stateless:

1. **Product.** Read `product:` from the repo's `.signapse/pipeline.yml`
   (`pipeline-config.sh product --required`: a missing file or key fails the
   gate; without `--required` the script prints nothing, which SIG-2760 uses
   for optional keys such as `sentry_project`); it names the directory under
   `terragrunt/products/` in signapse-core-terraform. The product is bound
   to the repo there: the gate sends `source_repo` (always
   `github.repository`, not an input) and `terraform-deploy.yml` refuses the
   run unless `.github/product-repos.txt` in signapse-core-terraform lists
   that repo for the product (signapse-core-terraform#508). A repo whose
   `pipeline.yml` names another product gets a `failed` verdict, never a plan.
2. **Token.** Mint a Prodzilla installation token narrowed to
   signapse-core-terraform with `actions: write` (dispatch, and read runs,
   logs and the artifact) and `pull-requests: read` (step 4). The train never
   holds the Terraform AWS role (ADR 0005).
3. **Dispatch and wait** (`terraform-gate.sh`). Dispatch
   `terraform-deploy.yml` on `main` with `product`, `environment`,
   `region: eu`, `action: plan`, `apply: true`, `source_repo` and a unique `run_key`
   (`<repo>-<run_id>-<attempt>-<env>-<n>`). Find the run whose title carries
   `[run_key]`, wait for it (`terraform_timeout_minutes`, default 45, at most
   50: wall clock including API calls, so the hour-long Prodzilla token
   outlives the wait and step 4) and read `verdict.json` from its
   `terraform-verdict` artifact:

   | Verdict | Gate |
   |---|---|
   | `no_changes`, run concluded `success` | pass, nothing applied |
   | `safe` and `applied`, run concluded `success` | pass, the run applied the creates and updates |
   | `no_changes` or `safe` from a run that did not conclude `success` | stop; Slack names the conclusion |
   | `blocked` | stop; Slack names the product, environment and the destroyed, replaced or unclassified resources (25 of each, then a count); the job summary lists them all |

   signapse-core-terraform decides `blocked` per environment (ADR 0002
   Decisions 19 and 33): prod blocks on any destroy or replace, stg only on a
   destroy or replace of a stateful resource type, dev never. The gate passes
   the verdict through.
   | `failed`, missing artifact, wrong product/environment, timeout | stop; Slack names the reason |

   A run that concludes `cancelled` was superseded in its concurrency group
   (GitHub keeps one pending run per product+environment), so it is
   re-dispatched, at most 4 dispatches in all. A `failed` run whose apply
   started and whose log says `Saved plan is stale` is re-dispatched once. A
   run still going at the timeout is left alone: it may be mid-apply.
4. **Unapplied Terraform PRs** (`terraform-pending.sh`, AC4). For each ticket
   in the Release Candidate, its Linear attachments that link a
   signapse-core-terraform PR. A merged PR is applied in the environment if,
   for every product it changes (every attachment is read; a ticket with more
   than 250 fails the gate rather than skip any) (`terragrunt/products/<P>/`; other
   `terraform/` or `terragrunt/` paths count as the promoted product), a
   successful `terraform-deploy.yml` apply run on `main` for that product (or
   `all`) and environment was created after the PR merged (every page of runs
   since the merge is read). A dispatch on
   `main` runs main's tip, so it contains every PR merged before it. In `dev`,
   orchestration's merge-apply run on the PR's merge commit also counts. This
   runs after step 3, so the gate's own run covers the promoted product; what
   it catches is a PR for another product, or one merged while the gate ran.
   Unmerged PRs only warn. `/apply-stg` and `/apply-prod` comment runs of
   orchestration.yml are not counted (their runs do not record which PR or
   environment they applied); dispatch `terraform-deploy.yml` for that
   product to clear the block.

Any stop posts the Slack alert, including one before the gate had a verdict
(missing inputs, product lookup, token mint).

The gate runs on every Promotion inside the window. Applying a safe plan
before a later check stops the Promotion is fine: infrastructure may run
ahead of code, never behind it.

### Prod (SIG-2769)

`release-train-prod.yml` runs the same action with `environment: prod`
before the prod deploy (see [Dark Deployment to prod](#dark-deployment-to-prod-sig-2769)).
terraform-deploy.yml runs every prod apply in signapse-core-terraform's
`prod-apply` environment, which waits for a `prod-approvers` reviewer (ADR
0002 Decisions 19 and 30). The gate's wait (`timeout_minutes`, at most 50)
includes that approval: with no approval in time the gate fails and nothing
is deployed.

### Dev

Not gated (a deviation from SIG-2765's summary, to be confirmed): dev is not
a Promotion, and orchestration.yml already applies a merged Terraform PR in dev.

### "Waits for the next window"

Nothing sleeps until the window opens. Outside the window the plan reports
`deferred`, the run ends green with nothing tagged, deployed or moved, and the
summary names the next opening. The caller's schedule re-runs the train: the
hourly backstop at :23 past each hour, plus a run just after 09:00 UK time on
weekdays (`1 8,9 * * 1-5` in UTC covers both GMT and BST; the run that falls
outside the window just defers). That run re-selects from scratch and promotes
whatever is the newest Release Candidate then, which includes the deferred
one. So a deferred Promotion lands within minutes of the window opening,
subject to GitHub's cron delays.

### Concurrency

One Promotion per repo at a time, and a running one is never cancelled. Two
layers:

- The caller template's workflow-level group `release-train-<repo>`
  (`cancel-in-progress: false`) serialises whole train runs.
- The `promote` job has its own group, `promotion-<repo>`, also
  `cancel-in-progress: false`. It holds even for a caller that does not use
  the template's group, or a second workflow that calls this one. Its name
  must differ from the caller's group: a job cannot join the group its own
  run holds, or it would wait for itself forever.

A second run waits for the first. GitHub keeps at most one *pending* run (or
job) per group, so with three runs the middle one is cancelled while still
queued, before it has done anything. With the template's workflow-level
group, the survivor's `select` runs after the first run finished, so it
re-selects from scratch and promotes the newest Release Candidate or reports
`already_promoted`. With only the job-level group, a queued `promote` keeps
the Release Candidate its `select` chose before it waited, which may be older
than what the first run just promoted. So the plan compares the last release
tag on the branch with the one `select` saw: if another Promotion tagged in
between, the decision is `superseded` and nothing is done (a higher tag on an
older commit would make Flux roll staging back). The next train run
re-selects.

### Re-runs and idempotency

- A Release Candidate whose commit already carries a release tag is reported
  `already_promoted` by `select`, and `promote` does not run. No second
  version is cut.
- ECR is tagged before git, and the git tag is what makes the next selection
  say `already_promoted`. If the run fails after the ECR tag but before the
  git tag, a re-run of the same Release Candidate computes the same version,
  finds the ECR tags already on the right digest (no-op) and adds the git
  tag. If instead the next run selects a newer Release Candidate, it computes
  the same version from git and `ecr-retag.sh` refuses to move the stray ECR
  tag: the run fails naming it and the `aws ecr batch-delete-image` command
  that removes it. Until someone deletes it, Flux's staging ImagePolicy may
  run that stray tag (the older build).
- If the run fails after the git tag (staging wait timed out, a ticket did
  not move), use **Re-run failed jobs** on that run. The plan sees the tag
  already on the commit (`resume`), skips the window check, re-verifies the
  images and finishes the wait and the ticket moves. A fresh run would report
  `already_promoted` and do nothing, by design: the hourly run must never move
  tickets back to On Staging after staging tests or prod have moved them on.

## Staging tests (SIG-2767)

`release-train-staging.yml` verifies a promoted Release Candidate on staging
(spec step 5). The caller runs it after the `train` job when `promoted` is
`'true'` (see the template below).

1. **Suite.** It calls signapse-e2e (`playwright.yml@main`, ADR 0002) with
   `environment: staging` and `tickets` = the train's `rc_tickets`: every
   live ticket from the tag prod runs to the Release Candidate, not only the
   ones new since the last Promotion. A tag that passed staging but has not
   reached prod is tested again with the new one, and the verdict lands on
   the same set prod deploys. On staging the suite runs those tickets' tests,
   `@smoke`, and the product suites the tickets' Linear labels point at, not
   the whole suite.
2. **Verdict** (job "Staging verdict", runs whatever the suite did,
   `scripts/staging-verdict.sh`). Pass means the suite job succeeded *and*
   reported `passed`. A failure, an error, a cancelled run (the suite reports
   `failed`) or a skipped job is a failure: an untested build never passes.
   - Pass: every ticket gets `Staging Passed`, loses `Staging Failed`, and
     gets a comment with the run and report links. The column stays On
     Staging. A ticket an earlier attempt sent to QA Failed (a re-run that
     flips the verdict) stays there, and `staging_passed` stays false until
     QA re-passes it.
   - Fail: every ticket gets `Staging Failed`, loses `Staging Passed`, gets
     the comment and moves to `QA Failed` (ADR 0001: the pipeline cannot
     blame one ticket), losing `QA Passed` (`scripts/qa-failed-tickets.sh`).
     QA approval does not survive QA Failed (spec "Board and labels"):
     without this, a fix merged later would be selectable on the old
     approval. A ticket in `Done` (a follow-up commit) stays in Done and
     keeps `QA Passed`, since it never went back to QA. A ticket whose move
     failed loses `QA Passed` anyway, so it still blocks the line. A Slack
     alert goes to `slack_channel`, naming which tickets are in QA Failed,
     which stayed where they were, and which Linear could not move. The run
     fails.
3. **Outputs.** `staging_passed` is `'true'` only on a pass that was recorded
   on every ticket, with no ticket in QA Failed; `report_url` links the Playwright report. Production
   (SIG-2769) runs only when `staging_passed == 'true'`.

Labels are added and removed one at a time (`issueAddLabel` /
`issueRemoveLabel`), so a ticket's other labels stay. The label to add is
looked up by name in the ticket's team, then in the workspace, once per team
and label. The comment is not repeated when the ticket already has one with
the same verdict and the same `Run:` line (exact match). Any Linear or
Slack error fails the job (and leaves `staging_passed` false) after every
ticket was attempted.

**Re-runs.** "Re-run failed jobs" re-runs the suite and the verdict. Labels
already right are left alone, the move to QA Failed is a no-op, and a ticket
that already has a comment for this run URL and verdict gets no second one. A
re-run that flips the verdict swaps the labels and comments the new verdict.
A failure alert goes to Slack on every failed attempt.

It is a separate workflow file, not jobs in `release-train.yml`, because
GitHub resolves every `uses:` workflow when a run is queued, even for jobs
that will be skipped. Referencing signapse-e2e from `release-train.yml` would
make every legacy `ready-for-prod` caller depend on it.

Inputs: `tickets` (required), `slack_channel` (required), `release_tag`. The
label and column names are the defaults `release-train.yml` uses, so the two
cannot disagree. Secrets:
`LINEAR_API_KEY`, `SLACK_BOT_TOKEN`, and the four forwarded to the suite
(`E2E_STAGING_SIGNSTUDIO_ADMIN_API_TOKEN`, `E2E_STAGING_SIGNSTUDIO_USER_EMAIL`,
`E2E_STAGING_SIGNSTUDIO_USER_PASSWORD`, `E2E_LINEAR_API_KEY`).

## Dark Deployment to prod (SIG-2769)

When staging passes, `release-train-prod.yml` deploys the Release Candidate to
prod (spec step 6, ADR 0004). QA does not have to act; a Prod approver (GitHub
team `prod-approvers`) approves the prod Terraform apply and the k8s
`deploy-prod` runs (Decisions 16 and 30, Alex, 2026-11-09), and the
`terraform_timeout_minutes` and `deploy_timeout_minutes` waits include that
approval. Feature tickets' flags
stay QA Cohort only, so customers see nothing new until a Rollout.

```text
prod (caller job, needs: [train, staging])
  deploy    prod-plan.sh          window (or hotfix) / deferred / already_deployed / nothing / refused
            feature-flag-guard    AC5: Feature flags QA Cohort only in prod (read-only)
            terraform-gate        AC2: product's prod stack, environment prod
            prod-deploy.sh        AC1: dispatch signapse-core-k8s deploy-prod.yml per service, wait
            prod-tags.sh          prod now runs the tag on every service
  release   deployment-release.yml@main   AC3: Linear Release (Deployed), Sentry release + production deploy
  smoke     signapse-e2e playwright.yml@main, environment prod, grep @prod-safe   AC4
  verdict   pass: flag guard again, tickets -> On Prod (only from on_prod_from)
            fail: the suite job failed and reported failed: prod_smoke_passed=false, run red
            unknown: anything else (e.g. `failed` from a cancelled suite): prod_smoke_passed empty, run red, smoke-unknown alerts
  rollback  after a failed smoke or a partial Deployment (SIG-2771): see "Automatic rollback" below
```

### Every ticket since prod's tag must have passed staging (both modes)

`prod-plan.sh` takes the tickets of every commit from the tag prod runs to
the tag it deploys (plus the `tickets` input), and checks each one in
Linear: it carries `Staging Passed`, does not carry `Staging Failed`, and is
not in `QA Failed`. Commits reverted later in that range, and revert commits,
add no tickets (`lib/revert.sh`, the same rule as the selection).

- **Fresh** (`release_tag` set, staging just passed): any ticket without a
  staging pass on record makes the decision `refused` and the run red. This
  is what stops a tag that failed staging (or was rolled back) from reaching
  prod inside a newer tag: its tickets are still in `QA Failed`.
- **Resume**: the same check gives `nothing`.

Neither mode deploys over a release tag the candidate does not contain (for
example a newer tag deployed by hand with deploy-prod.yml): fresh refuses,
resume gives `nothing`.

`Staging Passed` is cleared at every Promotion (SIG-2764), so it always
belongs to the newest tag's staging run.

### Deferral and resume (AC6)

Nothing is stored. A staging pass outside the deploy window ends with
`decision=deferred` and nothing done. The caller calls the prod workflow on
every run where staging was not attempted (`needs.staging.result ==
'skipped'`: nothing new promoted, a deferred Promotion, or a train that
failed), with `release_tag` empty. That is **resume mode**: take
`resume_tag` (the train's `staged_tag`: the newest selectable build that
already carries a release tag), or else the newest release tag on the
branch, and deploy it when, read fresh from Linear and signapse-core-k8s:

- prod does not run it yet on every service,
- prod never ran it and moved off it: no `Rolled-back-from: <tag>` trailer
  (rollback.yml) and no `deploy(prod): <svc> → <tag>` commit followed by
  another tag (a manual deploy-prod.yml rollback) in the service's prod file
  history (every page of it),
- it has at least one ticket, and every ticket since prod's tag has its
  staging pass on record (above),
- the deploy window is open (or a ticket carries `hotfix`).

The template's hourly and 09:01 schedules are the resume trigger. A
ticketless tag cannot prove its staging pass from Linear, so it waits for the
next Release Candidate (or a manual deploy). A train run that fails (a
blocked Terraform gate, a staging wait that timed out) no longer stops prod
from deploying an earlier tag that already passed staging.

### Ticket moves and the flag guard

- On a pass, tickets move to `On Prod` only from `on_prod_from` (default
  `On Staging`). A ticket already Rolling Out or Done (a follow-up commit)
  stays; nothing leaves `QA Failed`.
- The AC5 flag guard accepts a Feature flag's non-environment condition only
  when every property is the QA Cohort, `qa_cohort_id` (PostHog cohort id,
  created by SIG-2749). Another cohort, or no `qa_cohort_id` with Feature
  tickets to check, fails the guard. Every page of PostHog's flag search is
  read.
- The guard reads the PostHog **prod** project, `posthog_project_id_prod`
  (default `256388`). Decision (Alex, 2026-11-09) 10: each flag also exists
  in the dev project (`275880`), on for everyone; nothing here reads it.
- If the flag guard fails after a passed smoke, tickets do not move and a
  critical Slack alert (`<!channel>`) goes out. Nothing is rolled back: a
  widened flag is a PostHog change that an image rollback does not undo. If
  prod no longer runs the tag after a passed smoke (a rollback or a hand
  deploy replaced it), or the ticket move fails, tickets stay put and a plain
  alert goes out.
- A `refused` plan (no staging pass on record, a tag rolled back from
  before, or prod runs a release tag the candidate does not contain) alerts
  Slack too: later resume runs report `nothing` for the same reason.
- If a deploy-prod run or the final "prod runs the tag" check fails or times
  out, `scripts/prod-partial.sh` waits (up to 10 minutes) for any deploy-prod
  run still going (it pushes the tag before its rollout check), then re-reads
  the tags prod runs:
  - some dispatched services run the new tag: a failed Deployment.
    `partial_deployment` is `true`, `moved_services` lists them and
    `prod_smoke_passed` is `false`, so SIG-2771's rollback restores exactly
    them. Critical Slack alert naming them.
  - none does: prod is unchanged, nothing to roll back.
  - unknown (tags unreadable, or a run still going or never found while its
    service is not on the tag yet): never guessed. Critical Slack alert, no
    automatic rollback, `prod_smoke_passed` stays empty; a human checks.

### Idempotency and concurrency

- A service already running the tag is not dispatched again. If every service
  runs it (a re-run after the deploy), the decision is `already_deployed`:
  no window check, no Terraform gate, straight to release, smoke and verdict.
  The previous tag comes from deploy-prod's own commit message (`Previous:`).
- deployment-release.yml reuses the Release for the version.
- The `deploy` job holds `deployment-prod-<repo>`, never cancelled. The
  caller's workflow-level `release-train-<repo>` group serialises whole train
  runs, so one Deployment's smoke and verdict never overlap another's deploy.

### Finding the deploy-prod run

deploy-prod.yml takes `service` and `tag` today, with no `run_key` input and
no `run-name`. `prod-deploy.sh` correlates, best first: the run id the
dispatch API returns (`return_run_details`); a run titled with
`<run_key>-<service>`; exactly one new plain-titled run on `main` that did not
exist before the dispatch (more than one: fail as ambiguous, never guess). A
dispatch rejected with HTTP 422 for an unknown field starts nothing and is
retried without it. Required change in signapse-core-k8s: add a `run_key`
input and `run-name: ... [${{ inputs.run_key }}]` to deploy-prod.yml, like
rollback.yml.

### Outputs (for SIG-2771)

`decision`, `deployed`, `release_tag`, `version`, `sha`,
`tickets`, `dispatched_services`, `previous_tags` (`{service: tag}`),
`run_key` (service S was dispatched with `<run_key>-<S>`), `deploy_runs`,
`terraform_gate`, `terraform_run_url`, `linear_release_id`,
`linear_release_url`, `prod_smoke_passed` (`true`/`false` once deployed;
empty when nothing was deployed or the result is unknown; `false` after
a partial Deployment), `partial_deployment`, `moved_services`,
`smoke_report_url`, and from the rollback job `rolled_back`,
`rollback_results`, `incident_url`.

### Automatic rollback (SIG-2771)

The `rollback` job runs when the Deployment reached prod
(`deployed == 'true'`) and the smoke failed (`prod_smoke_passed == 'false'`),
or after a partial Deployment (`partial_deployment == 'true'`: a deploy-prod
run or the final check failed after some services moved). Then only
`moved_services` are rolled back, and there is no Linear Release to mark.
A cancelled train run never rolls back. The smoke result has three values:
`true` (the suite job succeeded and reported `passed`), `false` (the suite
reported `failed`) and empty, unknown: the suite gave no verdict (its job
errored, was cancelled or skipped before reporting, or reported `passed`
from a job that did not succeed), or the verdict job died before reading
it. Unknown is never treated as a pass or a failure: nothing is rolled back,
no ticket moves, and the `smoke-unknown` job posts a critical Slack alert and
ends the run red, because rolling back a Deployment that may be healthy is
worse than asking a human. Spec step 6 "Fail" and "Failure
handling":

```text
rollback
  prod-rollback.sh         AC1: signapse-core-k8s rollback.yml per service (Prodzilla, actions: write),
                           all dispatched, then waited on; restored tag checked against previous_tags
  release-rolled-back.sh   AC2: Linear Release -> `Rolled back` (canceled-type stage)
  rollback-incident.sh     AC3/AC5: incident.io incident, Cause = Deployment, link to the run
  rollback-tickets.sh      AC4/AC5: comment + QA Failed on every ticket (never out of Done),
                           QA Passed removed from those in QA Failed (qa-failed-tickets.sh),
                           Slack alert to slack_channel naming what moved, stayed or failed
  End red                  the run fails in every path
```

- **Tickets (Decision (Alex, 2026-11-09) 2).** Every ticket in the
  Deployment moves to `QA Failed` and loses `QA Passed`, except a ticket
  already in `Done`: it stays in `Done` and keeps `QA Passed`. It gets the
  comment, and the Slack alert lists it as stayed. SIG-2771's AC4 says the
  same.
- **No approval.** rollback.yml runs prod rollbacks in the `prod-rollback`
  GitHub environment, which has no required reviewers, so an automatic
  rollback never waits for a Prod approver (Decision 31, Alex, 2026-11-09;
  signapse-core-k8s#503).
- **Run keys.** Service S's rollback key is `<deploy run_key>-S-rollback`
  (rollback.yml shows it in its run title). When the run dispatched nothing
  (prod already ran the tag), the deploy key is `<repo>-<run id>-prod`.
- **Only from the release tag.** Right before dispatching, the job re-reads
  the tags prod runs. A service no longer on the release tag (a newer
  deployment or a manual rollback landed after the smoke) is not rolled back:
  `not_current`, needs a human. rollback.yml itself still picks its target
  from the tag history when it starts, so a deployment landing in the seconds
  between that read and rollback.yml's own resolution is not caught here;
  closing that needs rollback.yml to take the tag it must replace
  (signapse-core-k8s#503).
- **rollback.yml missing.** If signapse-core-k8s has no `rollback.yml`
  (SIG-2753, signapse-core-k8s#503 not merged), listing its runs returns 404:
  nothing is dispatched, every service is reported `missing_workflow` with a
  reason naming the workflow, the incident is Major and the Slack alert is
  critical (`<!channel>`). The run ends red.
- **Waiting.** Bounded by `rollback_timeout_minutes` (default 30, at most
  60 so the 90-minute job always reaches the incident and Slack steps) for
  all services together. A run still going at the limit is not cancelled.
  A bad value never stops the rollback: above 60 is used as 60, 0 or less
  as 30, and a fractional `rollback_max_attempts` is rounded down (below 1
  uses 3), each with a warning.
- **Cancelled.** A rollback that ends `cancelled` was displaced in the
  per-service concurrency queue. It is dispatched again with the same key, up
  to `rollback_max_attempts` (default 3) dispatches in all.
- **Verdict per service** from the `rollback-result` artifact (`rollback.json`):
  `success` with the restored tag equal to the tag prod ran before is ok.
  `no_previous_tag` (rollback.yml exit 3), `needs_human` (exit 4: the tag
  history is not clean pipeline changes), `failed`, a different restored tag,
  no artifact, a timeout or a failed dispatch all count as "the rollback
  failed" (AC5).
- **Incident.** One per Deployment, idempotency key `<repo>-<run id>-<release tag>-prod`: the same on every attempt of the run, so "Re-run all jobs" (new deploy key, or none when prod already runs the tag) finds the first incident.
  Severity (Decision (Alex, 2026-11-09) 3): an automatic rollback that
  restored every service is P3 (Minor), `incident_io_minor_severity_id`; a
  failed rollback is P2 (Major), `incident_io_major_severity_id`. The
  workspace has P1-P4 and no "Minor"/"Major". The Cause field is set to Deployment
  (dora-metrics counts it), and the run URL goes in the summary and the
  "Where did you find it? (URL)" link field. The Cause and link field ids are
  constants of Signapse's workspace in `rollback-incident.sh`. `incident_io_mode: test` opens a
  test incident instead, for trying the path out.
- **Release.** `linear_release_id` from the release job; if recording the
  Release failed, the Release is looked up by version in the pipeline. A
  Release moves to `Rolled back` only here, when prod's image was actually
  rolled back. A `/rollout-abort` does not touch the Release: it turns the
  flag off, the code stays dark-deployed and the ticket goes back to
  `On Prod`.
- **Slack.** Normal alert when rolled back. When the rollback failed it is
  critical (`<!channel>`) and names each service and the reason.
- **AC5: still records what it can.** Every step after the rollback runs
  whatever the rollback did, and a failure in one does not stop the next.
- **Re-runs.** To retry a failed rollback step (incident, Release, tickets,
  Slack), re-run **the "Roll back prod" job alone** (the job's re-run
  button), not "Re-run failed jobs". A single-job re-run reuses this
  attempt's smoke and verdict outputs, so the job runs again. "Re-run failed
  jobs" also re-runs a failed smoke, which now tests the restored prod: it
  can pass, and then the rollback job is skipped and its failed steps are
  never retried. In the re-run, a rollback that already succeeded with the
  key is reused (even if a later attempt with the key failed), one still
  running is waited on (read by id if newer runs push it off the listing), and a failed one is
  dispatched again with the same key (rollback.yml never rolls back twice
  for one key). The incident is not duplicated (idempotency key; the existing one is
  found by the run URL in its summary and linked again), and the
  Release move and ticket comments check first. The Slack alert is posted
  again, marked with the attempt number.
- **On Prod guard.** A re-run can re-run the smoke against the rolled-back
  prod. Before moving tickets to On Prod, the verdict job now checks that prod
  still runs the release tag on every service.
- prod-plan.sh already refuses a tag rollback.yml replaced, so the train
  never redeploys it by itself.

### Sentry production deploy marker

The production deploy marker now comes from deployment-release.yml after the
actual Deployment. `retag-release.yml` gained `sentry_environment` (default
`production`, so the legacy ready-for-prod flow is unchanged). A qa-passed
repo that still calls retag-release sets `sentry_environment: ''` so cutting
the tag records no production deploy. The qa-passed train itself tags through
the API and never calls retag-release.

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
    - cron: '1 8,9 * * 1-5' # 09:01 UK time on weekdays (GMT or BST): deferred Promotions

# One train run per repo at a time. A newer queued run replaces an older queued
# one, which is safe: every run re-reads everything and selects the same build.
# Do not name it promotion-<repo>: the reusable promote job uses that group.
concurrency:
  group: release-train-${{ github.repository }}
  cancel-in-progress: false

# GitHub checks every job of the called workflow against this grant before
# any `if:` runs, so it must cover the legacy jobs too (compose requests
# contents: write and checks: read), even though qa-passed mode skips them.
permissions:
  contents: write        # git tag for the Promotion
  pull-requests: read    # PR title and branch per commit
  checks: read
  actions: read          # main-push runs: which commits are builds
  id-token: write        # ECR role for the re-tag

jobs:
  train:
    uses: signapse/reusable-workflows/.github/workflows/release-train.yml@main
    with:
      selection_mode: qa-passed
      ticket: ${{ inputs.ticket }}
      trigger_id: ${{ inputs.trigger_id }}
      # build_workflow: main-push.yml   # if the build workflow has another file name
      prod_services: '["signstream-api","signstream-websocket"]'   # deploy-prod.yml service names
      # Promotion to staging (example: sign-stream-api). Before this goes
      # live, every listed service's staging ImagePolicy in signapse-core-k8s
      # must select semver release tags. Today stg signstream-websocket still
      # follows main-<n>-<sha> (numerical policy), so Flux would never pick
      # the release tag and the wait would time out (manual step).
      services: '["http","websocket","pip-worker"]'
      ecr_repo_prefix: signstream
      iam_role_arn: arn:aws:iam::827204657141:role/github-actions-connect
      staging_watch_paths: |
        workloads/stg/signstream-api/helmrelease-patch.yaml
        workloads/stg/signstream-websocket/helmrelease-patch.yaml
        workloads/stg/signstream-pip-worker/helmrelease-patch.yaml
      staging_version_url: |   # required; one per service with a version endpoint, JSON body with .version
        https://api.stg.signstream.example/version
      read_app_id: ${{ vars.PIPELINE_READ_APP_ID }}
      prodzilla_app_id: ${{ vars.PRODZILLA_APP_ID }}   # Terraform gate (SIG-2765)
    secrets:
      LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}
      READ_APP_PRIVATE_KEY: ${{ secrets.READ_APP_PRIVATE_KEY }}
      PRODZILLA_APP_PRIVATE_KEY: ${{ secrets.PRODZILLA_APP_PRIVATE_KEY }}
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}   # Terraform gate alerts

  # Verify on staging (SIG-2767). Production (SIG-2769) needs
  # needs.staging.outputs.staging_passed == 'true'.
  staging:
    needs: train
    if: needs.train.outputs.promoted == 'true'
    uses: signapse/reusable-workflows/.github/workflows/release-train-staging.yml@main
    permissions:
      contents: read     # every job inside needs only this; do not hand it the train's writes
    with:
      tickets: ${{ needs.train.outputs.rc_tickets }}
      release_tag: ${{ needs.train.outputs.release_tag }}
      slack_channel: '#signstream-releases'   # the repo's channel for failure alerts
    secrets:
      LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
      E2E_STAGING_SIGNSTUDIO_ADMIN_API_TOKEN: ${{ secrets.E2E_STAGING_SIGNSTUDIO_ADMIN_API_TOKEN }}
      E2E_STAGING_SIGNSTUDIO_USER_EMAIL: ${{ secrets.E2E_STAGING_SIGNSTUDIO_USER_EMAIL }}
      E2E_STAGING_SIGNSTUDIO_USER_PASSWORD: ${{ secrets.E2E_STAGING_SIGNSTUDIO_USER_PASSWORD }}
      E2E_LINEAR_API_KEY: ${{ secrets.E2E_LINEAR_API_KEY }}

  # Dark Deployment to prod (SIG-2769). Fresh after a staging pass; resume
  # (release_tag empty) on runs where staging was not attempted, which is how
  # a deferred Deployment reaches prod in the next window.
  prod:
    needs: [train, staging]
    # Fresh after a staging pass; resume whenever staging was not attempted
    # (nothing new, deferred, or the train failed), never after a staging
    # failure or a cancelled run.
    if: >-
      !cancelled() &&
      (needs.staging.outputs.staging_passed == 'true' || needs.staging.result == 'skipped')
    uses: signapse/reusable-workflows/.github/workflows/release-train-prod.yml@main
    permissions:
      contents: read
    with:
      release_tag: ${{ needs.staging.outputs.staging_passed == 'true' && needs.train.outputs.release_tag || '' }}
      resume_tag: ${{ needs.train.outputs.staged_tag }}
      tickets: ${{ needs.staging.outputs.staging_passed == 'true' && needs.train.outputs.rc_tickets || needs.train.outputs.staged_tickets }}
      qa_cohort_id: ${{ vars.POSTHOG_QA_COHORT_ID }}   # AC5 guard
      prod_services: '["signstream-api","signstream-websocket"]'   # deploy-prod.yml service names
      slack_channel: '#signstream-releases'
      read_app_id: ${{ vars.PIPELINE_READ_APP_ID }}
      prodzilla_app_id: ${{ vars.PRODZILLA_APP_ID }}
      # deployment_release_since: <sha>   # only for the pipeline's first Deployment
    secrets:
      LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}
      READ_APP_PRIVATE_KEY: ${{ secrets.READ_APP_PRIVATE_KEY }}
      PRODZILLA_APP_PRIVATE_KEY: ${{ secrets.PRODZILLA_APP_PRIVATE_KEY }}
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
      SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}
      POSTHOG_READ_API_KEY: ${{ secrets.POSTHOG_READ_API_KEY }}
      INCIDENT_IO_API_KEY: ${{ secrets.INCIDENT_IO_API_KEY }}
      E2E_PROD_SIGNSTUDIO_ADMIN_API_TOKEN: ${{ secrets.E2E_PROD_SIGNSTUDIO_ADMIN_API_TOKEN }}
      E2E_PROD_SIGNSTUDIO_USER_EMAIL: ${{ secrets.E2E_PROD_SIGNSTUDIO_USER_EMAIL }}
      E2E_PROD_SIGNSTUDIO_USER_PASSWORD: ${{ secrets.E2E_PROD_SIGNSTUDIO_USER_PASSWORD }}
```

`prod_services` and `read_app_id` (with secret `READ_APP_PRIVATE_KEY`) are
required unless `selection_base` is set: the walk starts at the tag prod
runs, read from `gitops_repo` with the read-only app.

Optional inputs: `qa_passed_label`, `qa_failed_state`, `build_workflow`,
`release_branch`, `release_tag_pattern`, `linear_team_key`, `aws_region`
(default `eu-west-2`), `staging_version_jq`, `on_staging_from`,
`staging_passed_label`, `staging_failed_label`,
`staging_deploy_timeout_minutes`, `gitops_repo`, `gitops_ref`,
`selection_base`, `on_staging_state`, `hotfix_label`,
`terraform_timeout_minutes` (default 45), `slack_releases_channel`. The Linear
defaults match the board after SIG-2747.

### Note for stages that dispatch other workflows (SIG-2765)

GitHub keeps at most one *pending* run per concurrency group. When a newer run
queues behind a running one, the older pending run is cancelled. This repo's
train is unaffected, because the run that survives re-selects from scratch.
But `terraform-deploy.yml` in signapse-core-terraform is serialised per
product and environment, so a run the train dispatched can conclude
`cancelled` without ever starting. Treat `cancelled` as "superseded, not
failed". Find the run that replaced it (or dispatch again) and wait for its
verdict. Do not report a Terraform failure or block the Promotion on it. The
Terraform gate re-dispatches (see [Terraform gate](#terraform-gate)).

## Prerequisites for switching a repo

- The build workflow tags images `main-<run_number>-<sha>`, as the reusable
  `main-push.yml` does, and its file name is `build_workflow`.
- The image is environment-agnostic: config comes at runtime, not baked in at
  build time. Later stages re-tag the selected image for staging and prod with
  no rebuild, so a dev-configured image would ship dev config.
- Prod runs a release tag of this repo on every `prod_services` entry, or
  `selection_base` is set for the first Deployment through the train.
- Staging follows release tags: each service's stg ImagePolicy in
  signapse-core-k8s is a semver policy over the same ECR repository (e.g.
  `workloads/stg/signstream-api/image-policy-stg.yaml`, range `>=0.0.0`), its
  stg ImageUpdateAutomation is not suspended, and the `$imagepolicy` setter is
  in the `staging_watch_paths` file. A stg policy that follows
  `main-<n>-<sha>` would never wait for the release tag.
- No ECR semver tag above the repo's highest git release tag. Flux picks the
  highest; the version is computed from git.
- `.signapse/pipeline.yml` declares `product:` (a `terragrunt/products/`
  directory with a `config/stg.yml` in signapse-core-terraform), the repo is
  listed for that product in signapse-core-terraform's
  `.github/product-repos.txt`, and the
  Prodzilla app is installed on signapse-core-terraform with
  `PRODZILLA_APP_ID`/`PRODZILLA_APP_PRIVATE_KEY` visible to the repo.
- The read-only pipeline app (ADR 0005) is installed on signapse-core-k8s,
  and the ECR role allows `ecr:BatchGetImage`, `ecr:DescribeImages` and
  `ecr:PutImage` on the service repositories.

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
  nothing. Add `actions: read`. Keep `SLACK_BOT_TOKEN`: the Terraform gate
  posts its alerts with it.
