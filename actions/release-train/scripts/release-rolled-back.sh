#!/usr/bin/env bash
# release-rolled-back.sh
#
# Marks a Deployment's Linear Release as rolled back (SIG-2771, AC2) by moving
# it to the pipeline's canceled-type stage named STAGE_NAME (default
# `Rolled back`). dora-metrics counts a Release in that stage (or any
# canceled-type stage) as a failed change.
#
# Which Release: RELEASE_ID (deployment-release.yml's linear_release_id) when
# set. When recording the Release failed earlier in the run, it is looked up by
# VERSION in LINEAR_PIPELINE instead; if none exists there is nothing to mark,
# which is reported (ok=false), not invented.
#
# Idempotent: a Release already in the stage is left alone (changed=false).
#
# Env:
#   RELEASE_ID       Linear Release id (may be empty)
#   VERSION          the Release's version (the release tag); for the lookup
#   LINEAR_PIPELINE  Linear release pipeline name; for the lookup
#   STAGE_NAME       default "Rolled back"
#   LINEAR_API_KEY   required
# Stdout: {ok, release_id, url, version, from_stage, stage, changed, reason}
# Exit 0 when the Release is in the stage, 1 otherwise (the object is still printed).

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

need jq
need curl

RELEASE_ID="${RELEASE_ID:-}"
VERSION="${VERSION:-}"
LINEAR_PIPELINE="${LINEAR_PIPELINE:-}"
STAGE_NAME="${STAGE_NAME:-Rolled back}"

release_json='{}'
from=""
out() { # out <ok> <changed> <reason>
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  jq -nc --argjson ok "$1" --argjson changed "$2" --arg why "$3" --argjson r "$release_json" \
    --arg from "$from" --arg stage "$STAGE_NAME" \
    '{ok: $ok, release_id: ($r.id // ""), url: ($r.url // ""), version: ($r.version // ""),
      from_stage: $from, stage: $stage, changed: $changed, reason: $why}'
  [ "$1" = true ] || exit 1
  exit 0
}

[ -n "${LINEAR_API_KEY:-}" ] || out false false "LINEAR_API_KEY not set"

errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
gql() { linear_gql "$@" 2> "$errf"; }

FIELDS='id url version stage{ id name type } pipeline{ name stages{ nodes{ id name type } } }'

if [ -n "$RELEASE_ID" ]; then
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  data=$(gql "query(\$id:String!){ release(id:\$id){ ${FIELDS} } }" "$(jq -nc --arg id "$RELEASE_ID" '{id:$id}')") \
    || out false false "could not read Release ${RELEASE_ID}: $(cat "$errf")"
  release_json=$(jq -c '.release // {}' <<< "$data")
else
  [ -n "$VERSION" ] && [ -n "$LINEAR_PIPELINE" ] \
    || out false false "no Release id, and no version and pipeline to look it up by"
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  data=$(gql 'query($name:String!){ releasePipelines(filter:{name:{eq:$name}}){ nodes{ id } } }' \
    "$(jq -nc --arg n "$LINEAR_PIPELINE" '{name:$n}')") || out false false "could not read pipeline ${LINEAR_PIPELINE}: $(cat "$errf")"
  pid=$(jq -r '.releasePipelines.nodes[0].id // empty' <<< "$data")
  [ -n "$pid" ] || out false false "Linear release pipeline '${LINEAR_PIPELINE}' not found"
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  data=$(gql "query(\$pid:ID!,\$v:String!){ releases(filter:{pipeline:{id:{eq:\$pid}}, version:{eq:\$v}}){ nodes{ ${FIELDS} } } }" \
    "$(jq -nc --arg p "$pid" --arg v "$VERSION" '{pid:$p, v:$v}')") || out false false "could not look up Release ${VERSION}: $(cat "$errf")"
  release_json=$(jq -c '.releases.nodes[0] // {}' <<< "$data")
  [ "$(jq -r '.id // ""' <<< "$release_json")" != "" ] \
    || out false false "no Release ${VERSION} in pipeline ${LINEAR_PIPELINE} (it was never recorded), so there is none to mark"
fi

[ "$(jq -r '.id // ""' <<< "$release_json")" != "" ] || out false false "Release ${RELEASE_ID} not found"
from=$(jq -r '.stage.name // ""' <<< "$release_json")

lc() { tr '[:upper:]' '[:lower:]' <<< "$1"; }
stage=$(jq -c --arg s "$(lc "$STAGE_NAME")" '[.pipeline.stages.nodes[]? | select((.name | ascii_downcase) == $s)] | first // empty' <<< "$release_json")
[ -n "$stage" ] || out false false "pipeline $(jq -r '.pipeline.name // "?"' <<< "$release_json") has no stage '${STAGE_NAME}' (has: $(jq -r '[.pipeline.stages.nodes[]?.name] | join(", ")' <<< "$release_json"))"
# dora-metrics counts a failed Deployment by the stage TYPE. A misconfigured
# stage still gets the Release (it is the closest record), but the result is
# not ok, so the run says the failure is not counted (review fix).
type=$(jq -r '.type // ""' <<< "$stage")
type_note=""
[ "$type" = canceled ] || type_note="; stage '${STAGE_NAME}' is type ${type:-unknown}, not canceled, so dora-metrics will not count this failed Deployment: fix the pipeline's stage"

if [ "$(lc "$from")" = "$(lc "$STAGE_NAME")" ]; then
  log "Release $(jq -r .version <<< "$release_json") is already in '${from}'"
  [ -z "$type_note" ] || out false false "already in ${from}${type_note}"
  out true false "already in ${from}"
fi

# shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
data=$(gql 'mutation($id:String!,$input:ReleaseUpdateInput!){ releaseUpdate(id:$id, input:$input){ success } }' \
  "$(jq -nc --arg id "$(jq -r .id <<< "$release_json")" --arg s "$(jq -r .id <<< "$stage")" '{id:$id, input:{stageId:$s}}')") \
  || out false false "could not move the Release to ${STAGE_NAME}: $(cat "$errf")"
[ "$(jq -r '.releaseUpdate.success // false' <<< "$data")" = true ] || out false false "releaseUpdate did not succeed"
log "Release $(jq -r .version <<< "$release_json"): ${from} -> ${STAGE_NAME}"
[ -z "$type_note" ] || out false true "moved from ${from} to ${STAGE_NAME}${type_note}"
out true true "moved from ${from} to ${STAGE_NAME}"
