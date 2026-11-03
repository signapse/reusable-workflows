# Deployment Release (`deployment-release.yml`)

Records each production Deployment in two places, under one version number (the Release Candidate's semver tag):

- a **Linear Release** in the product's Production release pipeline, created in stage `Deployed`, with the tickets found in the deployed commits attached. Commits with no ticket ref are listed in the Release description under "Untracked commits".
- a **Sentry release** with the identical version and a deploy to `production`, via the same pinned `getsentry/action-release` and settings as `retag-release.yml`.

Calling it twice with the same `version` gives one Linear Release (found by version in the pipeline, never re-created, and its stage left unchanged) and one Sentry release (Sentry keys releases by version). Each run adds a deploy record to that Sentry release, so a re-run shows two production deploys.

Call it from the **product repo** (the one that owns the version tag), not from signapse-core-k8s: it checks out the calling repo to read the tag and commits.

## Usage

Call it from the Deployment job once the image is running in production:

```yaml
jobs:
  deployment-release:
    uses: signapse/reusable-workflows/.github/workflows/deployment-release.yml@main
    with:
      version: ${{ needs.promote.outputs.tag }}    # e.g. v1.4.0
    secrets:
      LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}
      SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}
```

The pipeline name and Sentry project come from the product repo's `.signapse/pipeline.yml` (inputs override them):

```yaml
product: Signstream
linear_pipeline: SignStream   # exact name of the Linear release pipeline
sentry_project: signstream    # Sentry project slug; omit for no Sentry release (a warning is printed)
```

### Commit range

The Release lists tickets from commits in `since..sha`. By default `since` is the `commitSha` of the pipeline's latest Release, ignoring this version and Releases in a canceled stage (`Rolled back`). In other words, it's the last commit that actually reached prod. It deliberately isn't the previous git tag: a Release Candidate that failed staging is tagged but never deployed, so its tickets belong in the next Release. A pipeline's first Deployment has no earlier Release, so pass `since` explicitly there. On a re-run of a version that already has a Release, only Releases created before it count, so the range stays the same even if newer Deployments exist. A range with more than 250 ticket refs is refused (usually a wrong `since`).

Runs for the same repository and version are serialised (`concurrency`), so concurrent calls can't create two Releases.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `version` | yes | | Release Candidate's semver tag. Used verbatim as the Linear Release name and version and as the Sentry release version. |
| `sha` | no | commit of `version` | Commit the Deployment ships; also stored as the Release's `commitSha`. |
| `since` | no | latest Release's commit | Exclusive lower bound of the scanned range (`since..sha`). Required for the pipeline's first Deployment. |
| `linear_pipeline` | no | `linear_pipeline` in `.signapse/pipeline.yml` | Linear release pipeline name (exact match). |
| `linear_stage` | no | `Deployed` | Stage a new Release is created in. |
| `linear_team_key` | no | `SIG` | Team prefix for ticket refs in commit messages. |
| `sentry_org` | no | `signapse` | Sentry org slug. |
| `sentry_project` | no | `sentry_project` in `.signapse/pipeline.yml` | Sentry project slug. Still empty: Sentry is skipped with a `::warning::`. |
| `sentry_environment` | no | `production` | Sentry deploy environment. |
| `reusable_workflows_ref` | no | `main` | Ref of this repo to load the release-train scripts from. Pin it together with the `uses:` ref. |

## Outputs

| Output | Description |
|---|---|
| `linear_release_id` | Linear Release id. Use it with `releaseUpdate(id, {stageId})` to move the Release to `Rolling Out` / `Released` / `Rolled back`. |
| `linear_release_url` | Linear Release URL. |
| `linear_release_created` | `true` when this run created the Release, `false` when it already existed. |
| `tickets` | JSON array of ticket ids attached, e.g. `["SIG-1","SIG-2"]`. |
| `sentry_version` | The Sentry release version (equals `version`); empty when Sentry was skipped. |
| `since` | The commit the scanned range started after. |

The job summary shows the number of untracked commits (the list is in the Release description) and the ticket refs that do not exist in Linear. Ticket refs are resolved in one `issues` query; refs that are not Linear issues are absent from the result and reported, not fatal. Any error after that (auth, rate limit, bad release id) fails the run.

## Failure modes

- Pipeline not found: `Linear release pipeline '<name>' not found. Create it in Linear (Settings > Releases) or fix linear_pipeline in .signapse/pipeline.yml.`
- No pipeline name anywhere: `no linear_pipeline input and no .signapse/pipeline.yml`.
- Stage missing: `stage 'Deployed' not found in pipeline 'SignStream' (has: Released)`.
- No earlier Release in the pipeline and no `since`: `pipeline '<name>' has no earlier Release with a commit; pass 'since'` (first Deployment).
- Latest Release's commit not in this repo: pass `since`.

## Why the GraphQL API and not `linear-release-action`

The spec names `linear/linear-release-action`. It does not fit this pipeline's Release model:

- On a **continuous** pipeline, `sync` creates every Release directly in the completed stage, and `update` (stage moves) works only on **scheduled** pipelines. We need a Release that starts in `Deployed` and later moves to `Rolling Out` and `Released`.
- Creating in the completed stage fires Linear's "release completed" status automations, which could move tickets to Done at Deployment time instead of after the Stability Window.
- It authenticates with a per-pipeline access key (one secret per product pipeline), and it computes its own commit range from the pipeline's last Release rather than the Release Candidate's range.

So the step calls the Linear GraphQL API with the workspace `LINEAR_API_KEY` the release train already uses: `releasePipelines` (by name) → `releases` (latest non-canceled, for the range start) → `releases` (by pipeline + version) → `releaseCreate` (with `stageId`) → `issues` (team key + numbers) → `issueUpdate(addedReleaseIds)` per found issue. Tickets come from `ticket-extractor.sh`, the same extractor the release train uses.

## Linear pipeline setup (SIG-2748)

Each Production pipeline needs these stages. Stage `type` matters: Linear sets `completedAt`/`canceledAt` and fires release automations from the type.

| Stage | Type | Set by |
|---|---|---|
| `Deployed` | `started` | this workflow |
| `Rolling Out` | `started` | Rollout |
| `Released` | `completed` | Stability Window, once every ticket is Done |
| `Rolled back` | `canceled` | automatic rollback |

Linear has no separate release status field: a Release's lifecycle is its stage, and `Rolled back` is a stage of type `canceled`.

## Manual steps (not done by this change)

1. In Linear (SIG-2748): create the Production pipelines and add the stages above to each. Confirm a continuous pipeline accepts `started` and `canceled` stages; if it does not, make the pipelines scheduled.
2. Check the Engineering team's workflow automations for a "release completed" rule, and that it should fire on `Released` only.
3. GitHub: make `LINEAR_API_KEY` (workspace API key with write access to issues and releases) and `SENTRY_AUTH_TOKEN` (`project:releases`, `org:read`) available to each product repo that calls this workflow.
4. Add `linear_pipeline` and `sentry_project` to each product repo's `.signapse/pipeline.yml`.
