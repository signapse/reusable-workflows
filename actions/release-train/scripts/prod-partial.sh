#!/usr/bin/env bash
# prod-partial.sh
#
# After a deploy-prod run or the final "prod runs the tag" check failed or
# timed out (SIG-2769): which services did this Deployment already move to
# TAG? Prod running a mix of tags is a failed Deployment, so the moved
# services are what SIG-2771's rollback restores.
#
#   1. Waits (bounded by WAIT_SECONDS) for every deploy-prod run in RUNS that
#      has a run id and no conclusion yet: deploy-prod pushes the tag before
#      its rollout check, so a run still going can still move a service.
#   2. Re-reads the tags prod runs (prod-tags.sh, TAG_TRIES attempts).
#   3. state:
#        none     no dispatched service runs TAG: prod is unchanged
#        partial  moved = the dispatched services that run TAG
#        unknown  the tags could not be read, or a run is still going (or was
#                 never correlated) and its service does not run TAG yet: it
#                 may still move. Never guessed: no automatic rollback, a
#                 human decides (like an unknown smoke result).
#
# Env:
#   TAG            the release tag (required)
#   TO_DEPLOY      JSON array of the services this run dispatched (required)
#   RUNS           prod-deploy.sh's runs array (may be empty or [])
#   PROD_SERVICES, GITOPS_REPO, GITOPS_REF   passed to prod-tags.sh
#   READ_TOKEN     contents: read on the GitOps repo, for prod-tags.sh (required)
#   GH_TOKEN       actions: read on K8S_REPO, to follow runs (Prodzilla)
#   K8S_REPO       default signapse/signapse-core-k8s
#   WAIT_SECONDS   default 600; POLL_SECONDS default 15; TAG_TRIES default 3
#   PROD_TAGS      prod-tags command (default: prod-tags.sh next to this script)
# Stdout: {state, moved, reason}. Exit 0 whenever that object is printed;
# exit 1 only on bad input.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need gh
need jq

: "${TAG:?TAG not set}"
: "${TO_DEPLOY:?TO_DEPLOY not set}"
: "${READ_TOKEN:?READ_TOKEN not set}"
RUNS="${RUNS:-}"
[ -n "$RUNS" ] || RUNS='[]'
K8S_REPO="${K8S_REPO:-signapse/signapse-core-k8s}"
WAIT_SECONDS="${WAIT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-15}"
TAG_TRIES="${TAG_TRIES:-3}"
PROD_TAGS="${PROD_TAGS:-$(dirname "$0")/prod-tags.sh}"

for n in "$WAIT_SECONDS" "$POLL_SECONDS" "$TAG_TRIES"; do
  case "$n" in "" | *[!0-9]*) die "numeric env expected, got '$n'" ;; esac
done
[ "$POLL_SECONDS" -gt 0 ] || die "POLL_SECONDS must be > 0"
jq -e 'type == "array"' <<< "$TO_DEPLOY" > /dev/null 2>&1 || die "TO_DEPLOY must be a JSON array (got '$TO_DEPLOY')"
jq -e 'type == "array"' <<< "$RUNS" > /dev/null 2>&1 || die "RUNS must be a JSON array (got '$RUNS')"

out() { # out <state> <moved-json> <reason>
  jq -nc --arg s "$1" --argjson m "$2" --arg r "$3" '{state: $s, moved: $m, reason: $r}'
  exit 0
}

# 1. Follow unfinished runs until they finish or the wait runs out.
runs="$RUNS"
clock=0
open_runs() { jq -r '.[] | select((.run_id // "" | tostring) != "" and (.conclusion // "") == "") | .run_id | tostring' <<< "$runs"; }
open=$(open_runs)
while [ -n "$open" ]; do
  for id in $open; do
    if st=$(gh api "repos/${K8S_REPO}/actions/runs/${id}" --jq '[.status, (.conclusion // "")] | join(" ")' 2> /dev/null); then
      if [ "${st%% *}" = completed ]; then
        c="${st#* }"
        log "deploy-prod run ${id} finished: ${c}"
        runs=$(jq -c --arg id "$id" --arg c "${c:-unknown}" 'map(if (.run_id | tostring) == $id then .conclusion = $c else . end)' <<< "$runs")
      fi
    fi
  done
  open=$(open_runs)
  [ -n "$open" ] && [ "$clock" -lt "$WAIT_SECONDS" ] || break
  sleep "$POLL_SECONDS"
  clock=$((clock + POLL_SECONDS))
done

# 2. What prod runs now.
now=""
for ((i = 1; i <= TAG_TRIES; i++)); do
  if now=$(GH_TOKEN="$READ_TOKEN" "$PROD_TAGS" "$TAG"); then break; fi
  now=""
  [ "$i" -lt "$TAG_TRIES" ] && sleep "$POLL_SECONDS"
done
[ -n "$now" ] || out unknown '[]' "could not read the tags prod runs after ${TAG_TRIES} tries, so which services moved to ${TAG} is unknown"

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
moved=$(jq -c --argjson d "$TO_DEPLOY" '[.[] | select(.on_tag) | .service | select(. as $s | $d | index($s))]' <<< "$now")
# Dispatched services that do not run TAG but whose run has no conclusion
# (still going after the wait, or never correlated to a run id).
# shellcheck disable=SC2016
open=$(jq -r --argjson m "$moved" '[.[] | select((.conclusion // "") == "") | .service | select(. as $s | $m | index($s) | not)] | unique | join(", ")' <<< "$runs")
if [ -n "$open" ]; then
  out unknown "$moved" "deploy-prod for ${open} has not finished (or its run was never found), so it may still move to ${TAG}$( [ "$moved" = '[]' ] || jq -r '"; already on it: " + join(", ")' <<< "$moved")"
fi
[ "$moved" != '[]' ] || out none '[]' "no dispatched service runs ${TAG}: prod is unchanged"
out partial "$moved" "$(jq -r 'join(", ")' <<< "$moved") already run ${TAG}"
