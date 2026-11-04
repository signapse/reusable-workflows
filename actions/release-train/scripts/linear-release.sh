#!/usr/bin/env bash
# linear-release.sh <version> <until-ref> [since-ref]
#
# <version> is the Release Candidate's tag; the Release version is
# "${RELEASE_PREFIX}<version>" (default prefix "<repo name>@", see below).
#
# Records one Deployment as one Release in the product's Linear release
# pipeline. Idempotent on <version>: if the pipeline already has a Release
# with that version it is reused (its stage is left alone, so a re-run never
# pulls a Release back from Rolling Out / Released / Rolled back).
#
#   1. Resolve the pipeline by exact name (LINEAR_PIPELINE, else
#      `linear_pipeline` in $PIPELINE_CONFIG, default .signapse/pipeline.yml).
#   2. Commit range <since>..<until>. <since> defaults to the commitSha of the
#      pipeline's latest Release from this repo (same prefix) that is not
#      this version and not in a canceled stage (Rolled back): the last thing
#      from this repo that actually reached prod.
#      Not the previous git tag: a Release Candidate that failed staging is
#      tagged but never deployed, and its tickets must land in the next Release.
#   3. Look up a Release with that version in the pipeline; create it in stage
#      LINEAR_STAGE (default "Deployed") if there is none.
#   4. Attach every ticket ticket-extractor finds in the range. Commits with no
#      ticket are listed in the description as untracked; refs that are not
#      Linear issues are listed as not found.
#
# Uses the workspace GraphQL API (LINEAR_API_KEY), not linear-release-action:
# the action's access key is per pipeline and, on continuous pipelines, it
# always creates the Release in the completed stage. See
# docs/DEPLOYMENT-RELEASE.md.
#
# stdout: one JSON object
#   {"id","url","version","stage","created":bool,"since","tickets":[..],
#    "untracked":[..],"unresolved":[..]}

# shellcheck disable=SC2016 # GraphQL $variables are literal, not shell expansions
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

[ $# -ge 2 ] || die "usage: linear-release.sh <version> <until-ref> [since-ref]"
VERSION="$1"
UNTIL="$2"
SINCE="${3:-}"
[ -n "$VERSION" ] || die "version is empty"
TAG="$VERSION"
VERSION=$("$(dirname "$0")/release-version.sh" "$TAG")
# Prefix alone, to find this repo's earlier Releases in a shared pipeline.
RELEASE_PREFIX="${VERSION%"$TAG"}"

need git
need jq
need curl

STAGE_NAME="${LINEAR_STAGE:-Deployed}"
TEAM_KEY="${LINEAR_TEAM_KEY:-SIG}"
CONFIG="${PIPELINE_CONFIG:-.signapse/pipeline.yml}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# --- 1. pipeline ---------------------------------------------------------
pipeline_name="${LINEAR_PIPELINE:-}"
if [ -z "$pipeline_name" ]; then
  [ -f "$CONFIG" ] || die "no linear_pipeline input and no $CONFIG; add 'linear_pipeline: <name>' to $CONFIG"
  pipeline_name=$("$HERE/pipeline-config.sh" linear_pipeline "$CONFIG")
  [ -n "$pipeline_name" ] || die "$CONFIG has no linear_pipeline key"
fi

# gql <query> <vars-json> → .data, or die with Linear's error message.
gql() {
  local resp
  resp=$(linear_query "$1" "$2") || die "Linear API request failed"
  if [ "$(jq -r '(.errors // []) | length' <<<"$resp")" != "0" ]; then
    die "Linear API error: $(jq -r '[.errors[].message] | join("; ")' <<<"$resp")"
  fi
  jq -c '.data' <<<"$resp"
}

pipelines=$(gql 'query($name:String!){ releasePipelines(filter:{name:{eq:$name}}){ nodes{ id name type stages{ nodes{ id name type } } } } }' \
  "$(jq -nc --arg name "$pipeline_name" '{name:$name}')")
pipeline=$(jq -c '.releasePipelines.nodes[0] // empty' <<<"$pipelines")
if [ -z "$pipeline" ]; then
  die "Linear release pipeline '$pipeline_name' not found. Create it in Linear (Settings > Releases) or fix linear_pipeline in $CONFIG."
fi
pipeline_id=$(jq -r '.id' <<<"$pipeline")

# --- 2. existing Release for this version (idempotency) -------------------
existing=$(gql 'query($pid:ID!,$v:String!){ releases(filter:{pipeline:{id:{eq:$pid}}, version:{eq:$v}}){ nodes{ id url version stage{ name } createdAt } } }' \
  "$(jq -nc --arg pid "$pipeline_id" --arg v "$VERSION" '{pid:$pid, v:$v}')")
release=$(jq -c '.releases.nodes[0] // empty' <<<"$existing")

# --- 3. commit range ------------------------------------------------------
# On a re-run the range must end where this Release's own predecessor ended,
# not at a newer Release, so look only at Releases created before it.
git rev-parse --verify -q "${UNTIL}^{commit}" > /dev/null || die "unknown ref: $UNTIL"
if [ -z "$SINCE" ]; then
  before=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ -z "$release" ] || before=$(jq -r '.createdAt' <<<"$release")
  # Only this repo's Releases (same prefix): another repo's commit is not here.
  prev=$(gql 'query($pid:ID!,$v:String!,$p:String!,$before:DateTimeOrDuration!){ releases(first:50, orderBy:createdAt, filter:{pipeline:{id:{eq:$pid}}, and:[{version:{neq:$v}}, {version:{startsWith:$p}}], stage:{type:{neq:canceled}}, createdAt:{lt:$before}}){ nodes{ version commitSha createdAt } } }' \
    "$(jq -nc --arg pid "$pipeline_id" --arg v "$VERSION" --arg p "$RELEASE_PREFIX" --arg b "$before" '{pid:$pid, v:$v, p:$p, before:$b}')")
  latest=$(jq -c '[.releases.nodes[] | select(.commitSha != null and .commitSha != "")] | max_by(.createdAt) // empty' <<<"$prev")
  [ -n "$latest" ] || die "pipeline '$pipeline_name' has no earlier Release with a commit; pass 'since' (the last commit deployed to prod) for the first Deployment"
  SINCE=$(jq -r '.commitSha' <<<"$latest")
  git rev-parse --verify -q "${SINCE}^{commit}" > /dev/null \
    || die "latest Release $(jq -r '.version' <<<"$latest") points at $SINCE, which is not in this repo; pass 'since'"
  log "range starts after Release $(jq -r '.version' <<<"$latest") ($SINCE)"
fi
git rev-parse --verify -q "${SINCE}^{commit}" > /dev/null || die "unknown ref: $SINCE"

# --- 4. tickets + untracked commits ---------------------------------------
tickets=$(LINEAR_TEAM_KEY="$TEAM_KEY" "$HERE/ticket-extractor.sh" "$SINCE" "$UNTIL" < /dev/null)
# The issues lookup reads one page of 250, which covers any real Deployment.
# Refuse (before creating anything) rather than misreport page-2 issues.
[ "$(jq 'length' <<<"$tickets")" -le 250 ] || die "$(jq 'length' <<<"$tickets") ticket refs in range; more than 250 is not supported (check since)"

# One line per mainline commit whose own message, and every commit it merged
# in, carries no ticket ref. Walking --first-parent keeps a PR merge commit
# and its branch commits as one unit.
untracked=$(
  git rev-list --first-parent "${SINCE}..${UNTIL}" | while read -r c; do
    msgs=$(git log --format=%B "${c}^1..${c}" 2> /dev/null || git log -1 --format=%B "$c")
    if ! grep -qiE "${TEAM_KEY}-[0-9]+" <<<"$msgs"; then
      git log -1 --format='%h %s' "$c"
    fi
  done | jq -R . | jq -sc '.'
)

# --- 5. create the Release if missing ------------------------------------------

describe() { # <unresolved-json>
  local repo="${GITHUB_REPOSITORY:-}" sha
  sha=$(git rev-parse --short "${UNTIL}^{commit}")
  jq -rn --arg v "$VERSION" --arg repo "$repo" --arg sha "$sha" \
    --argjson t "$tickets" --argjson u "$untracked" --argjson n "$1" '
    "Deployment of \($v)" + (if $repo != "" then " (\($repo)@\($sha))" else " (\($sha))" end) + ".\n\n"
    + "Tickets: " + (if ($t|length) > 0 then ($t|join(", ")) else "none" end) + "\n"
    + (if ($u|length) > 0 then "\nUntracked commits (no ticket):\n" + ($u|map("- " + .)|join("\n")) + "\n" else "" end)
    + (if ($n|length) > 0 then "\nTicket refs not found in Linear: " + ($n|join(", ")) + "\n" else "" end)'
}

created=false
if [ -z "$release" ]; then
  stage_id=$(jq -r --arg s "$STAGE_NAME" '[.stages.nodes[] | select(.name == $s)][0].id // empty' <<<"$pipeline")
  if [ -z "$stage_id" ]; then
    die "stage '$STAGE_NAME' not found in pipeline '$pipeline_name' (has: $(jq -r '[.stages.nodes[].name] | join(", ")' <<<"$pipeline"))"
  fi
  # No commitSha yet: it is set after every ticket is attached (step 7), so a
  # run that fails half-way never becomes the default predecessor (that
  # lookup skips Releases without a commit) and its tickets are not skipped.
  input=$(jq -nc --arg pid "$pipeline_id" --arg sid "$stage_id" --arg v "$VERSION" \
    --arg d "$(describe '[]')" \
    '{pipelineId:$pid, stageId:$sid, name:$v, version:$v, description:$d}')
  out=$(gql 'mutation($input:ReleaseCreateInput!){ releaseCreate(input:$input){ success release{ id url version stage{ name } } } }' \
    "$(jq -nc --argjson i "$input" '{input:$i}')")
  release=$(jq -c '.releaseCreate.release // empty' <<<"$out")
  [ -n "$release" ] || die "releaseCreate returned no release"
  created=true
  log "created Release $VERSION in $pipeline_name / $STAGE_NAME"
else
  log "Release $VERSION already exists in $pipeline_name (stage $(jq -r '.stage.name' <<<"$release")); reusing it"
fi
release_id=$(jq -r '.id' <<<"$release")

# --- 6. attach tickets --------------------------------------------------
# Resolve all refs in one issues query: a ref that is not a Linear issue is
# simply absent from the result (reported as unresolved, not fatal), so no
# error-message matching is needed. Any error after that (auth, rate limit,
# bad release id) fails the run. addedReleaseIds is additive: re-runs no-op.
unresolved='[]'
if [ "$(jq 'length' <<<"$tickets")" -gt 0 ]; then
  numbers=$(jq -c 'map(split("-")[1] | tonumber)' <<<"$tickets")
  found=$(gql 'query($key:String!,$n:[Float!]){ issues(first:250, filter:{team:{key:{eq:$key}}, number:{in:$n}}){ nodes{ id identifier } } }' \
    "$(jq -nc --arg key "$TEAM_KEY" --argjson n "$numbers" '{key:$key, n:$n}')")
  unresolved=$(jq -c --argjson f "$found" '. - [$f.issues.nodes[].identifier]' <<<"$tickets")
  [ "$unresolved" = '[]' ] || log "WARN: not Linear issues: $(jq -r 'join(", ")' <<<"$unresolved")"
  for row in $(jq -c '.issues.nodes[]' <<<"$found"); do
    out=$(gql 'mutation($id:String!,$rid:String!){ issueUpdate(id:$id, input:{addedReleaseIds:[$rid]}){ success } }' \
      "$(jq -nc --arg id "$(jq -r '.id' <<<"$row")" --arg rid "$release_id" '{id:$id, rid:$rid}')")
    [ "$(jq -r '.issueUpdate.success // false' <<<"$out")" = "true" ] \
      || die "attaching $(jq -r '.identifier' <<<"$row") to Release $release_id failed"
  done
fi

# --- 7. finalise: description (true to what is attached) and commitSha ------
out=$(gql 'mutation($id:String!,$input:ReleaseUpdateInput!){ releaseUpdate(id:$id, input:$input){ success } }' \
  "$(jq -nc --arg id "$release_id" --arg d "$(describe "$unresolved")" --arg sha "$(git rev-parse "${UNTIL}^{commit}")" \
    '{id:$id, input:{description:$d, commitSha:$sha}}')")
[ "$(jq -r '.releaseUpdate.success // false' <<<"$out")" = "true" ] || die "releaseUpdate (description, commitSha) failed"

jq -nc --argjson r "$release" --argjson created "$created" --arg since "$SINCE" \
  --argjson t "$tickets" --argjson u "$untracked" --argjson n "$unresolved" \
  '{id:$r.id, url:$r.url, version:$r.version, stage:$r.stage.name, created:$created, since:$since,
    tickets:($t - $n), untracked:$u, unresolved:$n}'
