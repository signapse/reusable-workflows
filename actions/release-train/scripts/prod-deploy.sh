#!/usr/bin/env bash
# prod-deploy.sh
#
# Deploys a release tag to prod (SIG-2769, AC1) by dispatching
# signapse-core-k8s's deploy-prod.yml once per service, one at a time, and
# waiting for each run. The train never pushes to signapse-core-k8s:
# deploy-prod.yml commits the tag with the Flux app and reconciles (ADR 0005).
#
# Finding the run a dispatch started, best first:
#   1. dispatch_response  the dispatch API's run id (return_run_details).
#   2. run_key            a run whose display title contains RUN_KEY-<service>
#                         (needs deploy-prod.yml to take a `run_key` input and
#                         put it in `run-name`, like rollback.yml does).
#   3. only_new_run       exactly one deploy-prod run that did not exist before
#                         the dispatch, on K8S_REF, titled plainly
#                         DEFAULT_TITLE (no run-name, so no run_key). Two or
#                         more such runs: fail as ambiguous rather than guess.
# A dispatch the API rejects with HTTP 422 (unknown `run_key` input, or no
# return_run_details support) is retried without that field; a 422 starts
# nothing, so the retry cannot deploy twice.
#
# A run still going at the timeout is NOT cancelled; the result names it.
# `cancelled` is a failure, not a retry: deploy-prod is serialised per service
# with rollback.yml, so a cancel means a newer deploy or rollback replaced it,
# and re-dispatching could undo that.
#
# Env:
#   TAG              release tag to deploy (required)
#   SERVICES         JSON array of deploy-prod service names to deploy (required)
#   RUN_KEY          prefix; each service's dispatch gets RUN_KEY-<service> (required)
#   K8S_REPO         default signapse/signapse-core-k8s
#   DEPLOY_WORKFLOW  default deploy-prod.yml
#   K8S_REF          default main (deploy-prod.yml refuses any other ref)
#   DEFAULT_TITLE    deploy-prod's display title without run-name (default "Deploy to prod")
#   TIMEOUT_SECONDS  per service, finding + waiting (default 1800)
#   FIND_TIMEOUT_SECONDS  per service, until the run shows up (default 300)
#   POLL_SECONDS     default 15
#   GH_TOKEN         actions: write on K8S_REPO (Prodzilla, nothing else)
# Stdout: {ok, reason, runs: [{service, run_key, run_id, run_url, conclusion, correlated_by}]}
# Exit 0 whenever that object is printed; exit 1 only on bad input.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need gh
need jq

: "${TAG:?TAG not set}"
: "${SERVICES:?SERVICES not set}"
: "${RUN_KEY:?RUN_KEY not set}"
K8S_REPO="${K8S_REPO:-signapse/signapse-core-k8s}"
DEPLOY_WORKFLOW="${DEPLOY_WORKFLOW:-deploy-prod.yml}"
K8S_REF="${K8S_REF:-main}"
DEFAULT_TITLE="${DEFAULT_TITLE:-Deploy to prod}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"
FIND_TIMEOUT_SECONDS="${FIND_TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-15}"

[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || die "TAG is not a valid image tag: '$TAG'"
[[ "$RUN_KEY" =~ ^[A-Za-z0-9._:-]{1,60}$ ]] || die "RUN_KEY must be [A-Za-z0-9._:-], at most 60 characters (got '$RUN_KEY')"
for n in "$TIMEOUT_SECONDS" "$FIND_TIMEOUT_SECONDS" "$POLL_SECONDS"; do
  case "$n" in "" | *[!0-9]*) die "numeric env expected, got '$n'" ;; esac
done
[ "$POLL_SECONDS" -gt 0 ] || die "POLL_SECONDS must be > 0"
services=$(jq -r 'if type == "array" and all(type == "string" and test("^[a-z0-9][a-z0-9-]*$")) then .[] else error("bad") end' \
  <<< "$SERVICES" 2> /dev/null) || die "SERVICES must be a JSON array of deploy-prod service names (got '$SERVICES')"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

runs='[]'
svc="" key="" run_id="" run_url="" conclusion="" correlated_by=""

record() {
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  runs=$(jq -c --arg s "$svc" --arg k "$key" --arg id "$run_id" --arg u "$run_url" \
    --arg c "$conclusion" --arg by "$correlated_by" \
    '. + [{service: $s, run_key: $k, run_id: $id, run_url: $u, conclusion: $c, correlated_by: $by}]' <<< "$runs")
}

# result <ok> <reason>: print the result and stop.
result() {
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  jq -nc --argjson ok "$1" --arg r "$2" --argjson runs "$runs" '{ok: $ok, reason: $r, runs: $runs}'
  exit 0
}

list_runs() {
  gh api "repos/${K8S_REPO}/actions/workflows/${DEPLOY_WORKFLOW}/runs?event=workflow_dispatch&branch=${K8S_REF}&per_page=50" 2> "$work/err"
}

# dispatch: tries the richest request first and drops what the API rejects.
# Sets run_id (when the API returned it) and key_sent. Returns 2 on an HTTP
# 4xx (nothing started), 1 on any other failure (a 5xx or a timeout may still
# have started a run).
dispatch() {
  local with_key with_details body resp
  for variant in "key details" "details" "key" ""; do
    with_key=false with_details=false
    [[ "$variant" == *key* ]] && with_key=true
    [[ "$variant" == *details* ]] && with_details=true
    # shellcheck disable=SC2016 # jq bindings, not shell expansion.
    body=$(jq -nc --arg ref "$K8S_REF" --arg s "$svc" --arg t "$TAG" --arg k "$key" \
      --argjson wk "$with_key" --argjson wd "$with_details" '
      {ref: $ref, inputs: ({service: $s, tag: $t} + (if $wk then {run_key: $k} else {} end))}
      + (if $wd then {return_run_details: true} else {} end)')
    if resp=$(gh api -X POST "repos/${K8S_REPO}/actions/workflows/${DEPLOY_WORKFLOW}/dispatches" --input - <<< "$body" 2> "$work/err"); then
      key_sent=$with_key
      run_id=$(jq -r '(.workflow_run_id // .id // empty) | tostring' <<< "${resp:-null}" 2> /dev/null || true)
      [ "$run_id" != null ] || run_id=""
      log "dispatched ${DEPLOY_WORKFLOW} ${svc} ${TAG} (run_key input: ${with_key}, run id returned: ${run_id:-no})"
      return 0
    fi
    grep -q 'HTTP 422' "$work/err" || { grep -q 'HTTP 4[0-9][0-9]' "$work/err" && return 2; return 1; }
    log "dispatch rejected without starting a run (${variant:-plain}): $(cat "$work/err"); trying a simpler request"
  done
  return 2
}

# find_run: sets run_id, run_url, correlated_by.
find_run() {
  local waited=0 listed match
  if [ -n "$run_id" ]; then
    correlated_by=dispatch_response
  fi
  while :; do
    if listed=$(list_runs); then
      if [ -n "$run_id" ]; then
        run_url=$(jq -r --arg id "$run_id" '[.workflow_runs[]? | select((.id | tostring) == $id) | .html_url] | first // empty' <<< "$listed")
        [ -n "$run_url" ] || run_url="https://github.com/${K8S_REPO}/actions/runs/${run_id}"
        return 0
      fi
      if [ "$key_sent" = true ]; then
        match=$(jq -c --arg k "$key" '[.workflow_runs[]? | select((.display_title // "") | contains($k))] | first // empty' <<< "$listed")
        if [ -n "$match" ]; then
          run_id=$(jq -r '.id | tostring' <<< "$match")
          run_url=$(jq -r '.html_url' <<< "$match")
          correlated_by=run_key
          return 0
        fi
      fi
      # shellcheck disable=SC2016 # jq bindings, not shell expansion.
      match=$(jq -c --slurpfile before "$work/before" --arg ref "$K8S_REF" --arg title "$DEFAULT_TITLE" '
        [.workflow_runs[]? | select((.id as $id | any($before[0][]; . == $id) | not)
          and .head_branch == $ref and .display_title == $title)]' <<< "$listed")
      case "$(jq length <<< "$match")" in
        0) ;;
        1)
          run_id=$(jq -r '.[0].id | tostring' <<< "$match")
          run_url=$(jq -r '.[0].html_url' <<< "$match")
          correlated_by=only_new_run
          return 0 ;;
        *)
          run_url=$(jq -r 'map(.html_url) | join(" ")' <<< "$match")
          result false "could not tell which new ${DEPLOY_WORKFLOW} run is ours for ${svc} (candidates: ${run_url}); add a run_key input and run-name to deploy-prod.yml. Check prod by hand before re-running" ;;
      esac
    else
      log "listing ${DEPLOY_WORKFLOW} runs failed, retrying: $(cat "$work/err")"
    fi
    [ "$waited" -lt "$FIND_TIMEOUT_SECONDS" ] || return 1
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
  done
}

# wait_run: sets conclusion; false on timeout.
wait_run() {
  local waited=0 run status
  while :; do
    if run=$(gh api "repos/${K8S_REPO}/actions/runs/${run_id}" 2> "$work/err"); then
      status=$(jq -r '.status // ""' <<< "$run")
      if [ "$status" = completed ]; then
        conclusion=$(jq -r '.conclusion // ""' <<< "$run")
        log "${svc}: run ${run_id} completed: ${conclusion}"
        return 0
      fi
      log "${svc}: run ${run_id} is ${status:-?} (${waited}s of ${TIMEOUT_SECONDS}s)"
    else
      log "${svc}: reading run ${run_id} failed, retrying: $(cat "$work/err")"
    fi
    [ "$waited" -lt "$TIMEOUT_SECONDS" ] || return 1
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
  done
}

while IFS= read -r svc; do
  [ -n "$svc" ] || continue
  key="${RUN_KEY}-${svc}"
  run_id="" run_url="" conclusion="" correlated_by="" key_sent=false

  listed=$(list_runs) || result false "could not list ${DEPLOY_WORKFLOW} runs on ${K8S_REPO} before dispatching ${svc}: $(cat "$work/err")"
  jq -c '[.workflow_runs[]?.id]' <<< "$listed" > "$work/before"

  if dispatch; then :; else
    # Not a 4xx: the request may have started a run. Record the service with
    # no run id, so prod-partial.sh reports it as unknown, not unchanged.
    [ "$?" -eq 2 ] || record
    result false "could not dispatch ${DEPLOY_WORKFLOW} for ${svc} on ${K8S_REPO}: $(cat "$work/err")"
  fi
  if ! find_run; then
    record
    result false "no ${DEPLOY_WORKFLOW} run for ${svc} showed up within ${FIND_TIMEOUT_SECONDS}s of the dispatch; check ${K8S_REPO} Actions before re-running"
  fi
  log "${svc}: following ${run_url} (found by ${correlated_by})"
  if ! wait_run; then
    record
    result false "timed out after ${TIMEOUT_SECONDS}s waiting for ${svc}'s deploy (${run_url}); it was NOT cancelled and may still finish"
  fi
  record
  [ "$conclusion" = success ] || result false "${svc}'s deploy-prod run concluded ${conclusion:-unknown} (${run_url}); prod may run a mix of tags"
done <<< "$services"

result true "deployed ${TAG}"
