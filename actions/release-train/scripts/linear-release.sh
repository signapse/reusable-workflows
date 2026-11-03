#!/usr/bin/env bash
# linear-release.sh <version> <since-ref> <until-ref>
#
# Records one Deployment as one Release in the product's Linear release
# pipeline. Idempotent on <version>: if the pipeline already has a Release
# with that version it is reused (its stage is left alone, so a re-run never
# pulls a Release back from Rolling Out / Released / Rolled back).
#
#   1. Resolve the pipeline by exact name (LINEAR_PIPELINE, else
#      `linear_pipeline` in $PIPELINE_CONFIG, default .signapse/pipeline.yml).
#   2. Look up a Release with that version in the pipeline; create it in stage
#      LINEAR_STAGE (default "Deployed") if there is none.
#   3. Attach every ticket ticket-extractor finds in <since>..<until>.
#      Commits with no ticket are listed in the description as untracked.
#
# Uses the workspace GraphQL API (LINEAR_API_KEY), not linear-release-action:
# the action's access key is per pipeline and, on continuous pipelines, it
# always creates the Release in the completed stage. See
# docs/DEPLOYMENT-RELEASE.md.
#
# stdout: one JSON object
#   {"id","url","version","stage","created":bool,"tickets":[..],
#    "untracked":[..],"unresolved":[..]}

# shellcheck disable=SC2016 # GraphQL $variables are literal, not shell expansions
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

[ $# -ge 3 ] || die "usage: linear-release.sh <version> <since-ref> <until-ref>"
VERSION="$1"
SINCE="$2"
UNTIL="$3"
[ -n "$VERSION" ] || die "version is empty"

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
  # Flat key per the .signapse/pipeline.yml contract; strip comment and quotes.
  pipeline_name=$(sed -n 's/^linear_pipeline:[[:space:]]*//p' "$CONFIG" | head -1 \
    | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//")
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

# --- 2. tickets + untracked commits ---------------------------------------
git rev-parse --verify -q "${UNTIL}^{commit}" > /dev/null || die "unknown ref: $UNTIL"
git rev-parse --verify -q "${SINCE}^{commit}" > /dev/null || die "unknown ref: $SINCE"

tickets=$(LINEAR_TEAM_KEY="$TEAM_KEY" "$HERE/ticket-extractor.sh" "$SINCE" "$UNTIL" < /dev/null)

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

# --- 3. find or create the Release ------------------------------------------
existing=$(gql 'query($pid:ID!,$v:String!){ releases(filter:{pipeline:{id:{eq:$pid}}, version:{eq:$v}}){ nodes{ id url version stage{ name } } } }' \
  "$(jq -nc --arg pid "$pipeline_id" --arg v "$VERSION" '{pid:$pid, v:$v}')")
release=$(jq -c '.releases.nodes[0] // empty' <<<"$existing")

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
  sha=$(git rev-parse "${UNTIL}^{commit}")
  input=$(jq -nc --arg pid "$pipeline_id" --arg sid "$stage_id" --arg v "$VERSION" \
    --arg sha "$sha" --arg d "$(describe '[]')" \
    '{pipelineId:$pid, stageId:$sid, name:$v, version:$v, commitSha:$sha, description:$d}')
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

# --- 4. attach tickets (addedReleaseIds is additive, so re-runs are no-ops) --
unresolved='[]'
for t in $(jq -r '.[]' <<<"$tickets"); do
  resp=$(linear_query 'mutation($id:String!,$rid:String!){ issueUpdate(id:$id, input:{addedReleaseIds:[$rid]}){ success } }' \
    "$(jq -nc --arg id "$t" --arg rid "$release_id" '{id:$id, rid:$rid}')") || resp='{}'
  if [ "$(jq -r '.data.issueUpdate.success // false' <<<"$resp")" != "true" ]; then
    log "WARN: could not attach $t: $(jq -r '[.errors[]?.message] | join("; ")' <<<"$resp" 2> /dev/null)"
    unresolved=$(jq -c --arg t "$t" '. + [$t]' <<<"$unresolved")
  fi
done

# Keep the description true to what is attached (also refreshes it on re-run).
if [ "$created" = true ] && [ "$unresolved" = '[]' ]; then
  :
else
  gql 'mutation($id:String!,$d:String!){ releaseUpdate(id:$id, input:{description:$d}){ success } }' \
    "$(jq -nc --arg id "$release_id" --arg d "$(describe "$unresolved")" '{id:$id, d:$d}')" > /dev/null
fi

jq -nc --argjson r "$release" --argjson created "$created" \
  --argjson t "$tickets" --argjson u "$untracked" --argjson n "$unresolved" \
  '{id:$r.id, url:$r.url, version:$r.version, stage:$r.stage.name, created:$created,
    tickets:($t - $n), untracked:$u, unresolved:$n}'
