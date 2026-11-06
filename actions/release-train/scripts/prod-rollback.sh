#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq bindings ($r, $m, ...) in single quotes throughout, not shell expansion.
# prod-rollback.sh
#
# Automatic rollback after a failed prod @prod-safe smoke (SIG-2771, AC1, AC5;
# spec step 6 "Fail"). For each service, dispatches signapse-core-k8s
# rollback.yml (SIG-2753) with a run key derived from that service's
# deploy-prod run key, follows the run, reads its `rollback-result` artifact
# (rollback.json) and checks that the restored tag is the one prod ran before
# the Deployment (previous_tags from release-train-prod.yml's deploy job).
# The train never pushes to signapse-core-k8s: rollback.yml pins the tag with
# the Flux app (ADR 0005).
#
# All services are dispatched first, then waited on together: each one has
# its own concurrency group (deploy-prod-<service>), so they roll back in
# parallel and prod is back on the old tags as early as possible.
#
# Idempotent, keyed on the rollback run key (rollback.yml puts it in its
# run-name, and its resolver never rolls back twice for one key):
#   - a run with the key that succeeded already is reused, nothing dispatched;
#   - one still queued or running is waited on;
#   - otherwise (none, failed, cancelled) the rollback is dispatched with the
#     same key. A failed earlier attempt is retried this way on "Re-run".
# Within one invocation, a run that ends `cancelled` (a newer deploy or
# rollback of the same service displaced it while queued) is dispatched again
# with the SAME key, at most MAX_ATTEMPTS times in all (OPERATIONS.md in
# signapse-core-k8s). `failure` is never re-dispatched within an invocation.
#
# Per service, rollback.json `result`:
#   success          ok when restored == the expected previous tag (AC1)
#   no_previous_tag  exit 3 in rollback.yml: nothing to roll back to
#   needs_human      exit 4: the history isn't clean pipeline changes
#   failed           anything else (ECR, Flux suspended, stg automation, ...)
#   not_current      CURRENT_TAGS shows the service on another tag than
#                    RELEASE_TAG: nothing dispatched, needs a human
#   missing_workflow ROLLBACK_WORKFLOW does not exist on K8S_REPO (404): nothing
#                    is dispatched, every service needs a human
# Every non-ok service sets needs_human=true in the result (AC5: Major).
#
# Env:
#   SERVICES          JSON array of services to roll back (required)
#   PREVIOUS_TAGS     JSON object service -> tag prod ran before (may be {})
#   RELEASE_TAG       the tag being rolled back from; without a previous tag,
#                     a rollback is ok only if it restored something else
#   CURRENT_TAGS      optional prod-tags.sh output read just before: a service
#                     that no longer runs RELEASE_TAG (a newer deployment landed
#                     after the smoke) is not rolled back, it needs a human
#                     (result not_current), so a rollback never undoes it
#   DEPLOY_RUN_KEY    the deploy job's run key; service S's deploy-prod key is
#                     DEPLOY_RUN_KEY-S and its rollback key DEPLOY_RUN_KEY-S-rollback (required)
#   K8S_REPO          default signapse/signapse-core-k8s
#   ROLLBACK_WORKFLOW default rollback.yml
#   K8S_REF           default main (rollback.yml refuses any other ref)
#   TIMEOUT_SECONDS   overall wait for every rollback (default 1800)
#   FIND_TIMEOUT_SECONDS  per dispatch, until its run shows up (default 300)
#   MAX_ATTEMPTS      dispatches per service, counting re-dispatches after cancel (default 3)
#   POLL_SECONDS      default 15
#   GH_TOKEN          actions: write on K8S_REPO (Prodzilla, nothing else)
# Stdout: {ok, needs_human, reason, results: [{service, run_key, run_id, run_url,
#   conclusion, attempts, result, expected, restored, replaced, restored_commit,
#   restored_commit_date, ok, reason}]}
# Exit 0 whenever that object is printed; exit 1 only on bad input.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need gh
need jq

: "${SERVICES:?SERVICES not set}"
: "${DEPLOY_RUN_KEY:?DEPLOY_RUN_KEY not set}"
PREVIOUS_TAGS="${PREVIOUS_TAGS:-}"
[ -n "$PREVIOUS_TAGS" ] || PREVIOUS_TAGS='{}'
K8S_REPO="${K8S_REPO:-signapse/signapse-core-k8s}"
ROLLBACK_WORKFLOW="${ROLLBACK_WORKFLOW:-rollback.yml}"
K8S_REF="${K8S_REF:-main}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"
FIND_TIMEOUT_SECONDS="${FIND_TIMEOUT_SECONDS:-300}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
POLL_SECONDS="${POLL_SECONDS:-15}"

for n in "$TIMEOUT_SECONDS" "$FIND_TIMEOUT_SECONDS" "$MAX_ATTEMPTS" "$POLL_SECONDS"; do
  case "$n" in "" | *[!0-9]*) die "numeric env expected, got '$n'" ;; esac
done
[ "$POLL_SECONDS" -gt 0 ] || die "POLL_SECONDS must be > 0"
[ "$MAX_ATTEMPTS" -gt 0 ] || die "MAX_ATTEMPTS must be > 0"
CURRENT_TAGS="${CURRENT_TAGS:-}"
[ -z "$CURRENT_TAGS" ] || jq -e 'type == "array"' <<< "$CURRENT_TAGS" > /dev/null 2>&1 || die "CURRENT_TAGS must be prod-tags.sh's JSON array (got '$CURRENT_TAGS')"
jq -e 'type == "object"' <<< "$PREVIOUS_TAGS" > /dev/null 2>&1 || die "PREVIOUS_TAGS must be a JSON object (got '$PREVIOUS_TAGS')"
services=$(jq -r 'if type == "array" and length > 0 and all(type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")) then .[] else error("bad") end' \
  <<< "$SERVICES" 2> /dev/null) || die "SERVICES must be a non-empty JSON array of service names (got '$SERVICES')"

# Seconds spent polling (sleeps), so the limits hold whatever the API latency.
clock=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Per-service state, one JSON object per service in $work/state/<svc>.json.
mkdir -p "$work/state"
st() { jq -r --arg k "$2" '.[$k] // "" | tostring' "$work/state/$1.json"; }
st_set() { # st_set <svc> <jq-assignments> [--arg ...]
  local svc="$1" expr="$2"
  shift 2
  jq -c "$@" "$expr" "$work/state/$svc.json" > "$work/s" && mv "$work/s" "$work/state/$svc.json"
}

list_runs() {
  gh api "repos/${K8S_REPO}/actions/workflows/${ROLLBACK_WORKFLOW}/runs?event=workflow_dispatch&branch=${K8S_REF}&per_page=100" 2> "$work/err"
}

# runs_for_key <listing> <key>: our runs, newest first. rollback.yml's run-name
# is "Rollback <svc> (<env>) [<run_key>]".
runs_for_key() {
  jq -c --arg k "[$2]" '[.workflow_runs[]? | select((.display_title // "") | endswith($k))] | sort_by(.id) | reverse' <<< "$1"
}

dispatch() { # dispatch <svc>
  local svc="$1" key body
  key=$(st "$svc" key)
  body=$(jq -nc --arg ref "$K8S_REF" --arg s "$svc" --arg k "$key" \
    '{ref: $ref, inputs: {service: $s, environment: "prod", run_key: $k}}')
  gh api -X POST "repos/${K8S_REPO}/actions/workflows/${ROLLBACK_WORKFLOW}/dispatches" --input - <<< "$body" > /dev/null 2> "$work/err" || return 1
  st_set "$svc" '.attempts += 1 | .run_id = "" | .run_url = "" | .status = "dispatched" | .dispatched_at = $now' --argjson now "$clock"
  log "${svc}: dispatched ${ROLLBACK_WORKFLOW} (prod, run key ${key}, attempt $(st "$svc" attempts))"
}

finish() { # finish <svc> <conclusion> <result> <ok> <reason>
  st_set "$1" '.status = "done" | .conclusion = $c | .result = $r | .ok = $ok | .reason = $why' \
    --arg c "$2" --arg r "$3" --argjson ok "$4" --arg why "$5"
}

# evaluate <svc> <conclusion>: read rollback.json and decide.
evaluate() {
  local svc="$1" conclusion="$2" id dir f result restored expected
  id=$(st "$svc" run_id)
  dir="$work/art-$svc-$id"
  rm -rf "$dir"
  if gh run download "$id" -R "$K8S_REPO" -n rollback-result -D "$dir" > /dev/null 2> "$work/err" && [ -f "$dir/rollback.json" ]; then
    f="$dir/rollback.json"
    st_set "$svc" '.restored = ($j.restored // "") | .replaced = ($j.replaced // "")
      | .restored_commit = ($j.restored_commit // "") | .restored_commit_date = ($j.restored_commit_date // "")' \
      --argjson j "$(jq -c . "$f")"
    result=$(jq -r '.result // ""' "$f")
  else
    log "${svc}: no rollback.json on run ${id}: $(cat "$work/err")"
    result=""
  fi
  restored=$(st "$svc" restored)
  expected=$(st "$svc" expected)
  case "$result" in
    success)
      if [ "$conclusion" != success ]; then
        finish "$svc" "$conclusion" "$result" false "rollback.json says success but the run concluded ${conclusion}"
      elif [ -z "$expected" ]; then
        # No previous tag to compare with (review fix): ok only when what
        # runs now is provably not the failed tag. Otherwise a human checks.
        if [ -n "${RELEASE_TAG:-}" ] && [ -n "$restored" ] && [ "$restored" != "$RELEASE_TAG" ]; then
          finish "$svc" "$conclusion" "$result" true "restored ${restored}, not ${RELEASE_TAG}; the Deployment recorded no previous tag to check it against"
        else
          finish "$svc" "$conclusion" "$result" false "needs a human: restored ${restored:-nothing}, and the Deployment recorded no previous tag to verify it against${RELEASE_TAG:+ (failed tag ${RELEASE_TAG})}"
        fi
      elif [ "$restored" = "$expected" ]; then
        finish "$svc" "$conclusion" "$result" true "restored ${restored}"
      else
        finish "$svc" "$conclusion" "$result" false "restored ${restored:-nothing}, but prod ran ${expected} before the Deployment"
      fi ;;
    no_previous_tag) finish "$svc" "$conclusion" "$result" false "needs a human: no previous tag to roll back to (exit 3); nothing was changed" ;;
    needs_human) finish "$svc" "$conclusion" "$result" false "needs a human: the tag history is not clean pipeline changes (exit 4); nothing was changed" ;;
    failed) finish "$svc" "$conclusion" "$result" false "rollback failed${restored:+ restoring ${restored}}; see the run" ;;
    *) finish "$svc" "$conclusion" "${result:-unknown}" false "rollback run concluded ${conclusion} with no readable rollback.json" ;;
  esac
}

# Seed state, then adopt or dispatch.
if ! listed=$(list_runs); then
  # rollback.yml (SIG-2753) is not on K8S_REPO: nothing can be rolled back.
  # Say so plainly (every service not ok, needs a human) instead of a generic
  # script failure, so the critical alert names the missing workflow.
  if grep -qiE 'HTTP 404|Not Found' "$work/err"; then
    why="${ROLLBACK_WORKFLOW} does not exist on ${K8S_REPO} (SIG-2753, signapse-core-k8s#503 not merged?); nothing was rolled back, roll back by hand (signapse-core-k8s docs/OPERATIONS.md)"
    log "$why"
    mapfile -t svcs <<< "$services"
    jq -nc --arg why "$why" --argjson p "$PREVIOUS_TAGS" --arg k "$DEPLOY_RUN_KEY" '
      [$ARGS.positional[] | {service: ., run_key: "\($k)-\(.)-rollback", run_id: "", run_url: "", conclusion: "",
        attempts: 0, result: "missing_workflow", expected: ($p[.] // ""), restored: "", replaced: "",
        restored_commit: "", restored_commit_date: "", ok: false, reason: $why}]
      | {ok: false, needs_human: true, reason: $why, results: .}' --args "${svcs[@]}"
    exit 0
  fi
  die "could not list ${ROLLBACK_WORKFLOW} runs on ${K8S_REPO}: $(cat "$work/err")"
fi
while IFS= read -r svc; do
  [ -n "$svc" ] || continue
  key="${DEPLOY_RUN_KEY}-${svc}-rollback"
  [[ "$key" =~ ^[A-Za-z0-9._:-]{1,100}$ ]] || die "rollback run key '$key' is not valid for rollback.yml ([A-Za-z0-9._:-], max 100)"
  jq -nc --arg s "$svc" --arg k "$key" --arg e "$(jq -r --arg s "$svc" '.[$s] // ""' <<< "$PREVIOUS_TAGS")" \
    '{service: $s, run_key: $k, key: $k, expected: $e, attempts: 0, run_id: "", run_url: "", status: "",
      conclusion: "", result: "", restored: "", replaced: "", restored_commit: "", restored_commit_date: "",
      ok: false, reason: "", dispatched_at: 0, known: []}' > "$work/state/$svc.json"
  mine=$(runs_for_key "$listed" "$key")
  # Every run with this key that exists now is an earlier attempt, not ours.
  st_set "$svc" '.known = [$m[].id]' --argjson m "$mine"
  latest=$(jq -c 'first // empty' <<< "$mine")
  # Any earlier success with this key is reused, even if a later attempt
  # with the same key failed or was cancelled (rollback.yml never rolls back
  # twice for one key, so that success is the rollback).
  done_ok=$(jq -c '[.[] | select(.status == "completed" and .conclusion == "success")] | first // empty' <<< "$mine")
  current=""
  [ -z "$CURRENT_TAGS" ] || current=$(jq -r --arg s "$svc" '[.[] | select(.service == $s) | .current_tag][0] // ""' <<< "$CURRENT_TAGS")
  if [ -n "$done_ok" ]; then
    st_set "$svc" '.run_id = ($r.id | tostring) | .run_url = $r.html_url | .attempts = 1' --argjson r "$done_ok"
    log "${svc}: already rolled back by an earlier attempt: $(st "$svc" run_url)"
    evaluate "$svc" success
  elif [ -n "$latest" ] && [ "$(jq -r '.status' <<< "$latest")" != completed ]; then
    st_set "$svc" '.run_id = ($r.id | tostring) | .run_url = $r.html_url | .status = "running" | .attempts = 1' --argjson r "$latest"
    log "${svc}: an earlier attempt's rollback is still going, following it: $(st "$svc" run_url)"
  elif [ -n "$current" ] && [ -n "${RELEASE_TAG:-}" ] && [ "$current" != "$RELEASE_TAG" ]; then
    finish "$svc" "" not_current false "needs a human: prod runs ${current}, not ${RELEASE_TAG}, so a newer deployment (or a manual rollback) landed after the smoke; not rolled back"
    log "${svc}: $(st "$svc" reason)"
  else
    dispatch "$svc" || finish "$svc" "" not_dispatched false "could not dispatch ${ROLLBACK_WORKFLOW}: $(tail -n 1 "$work/err")"
  fi
done <<< "$services"

pending() { jq -s -r '[.[] | select(.status != "done")] | length' "$work/state/"*.json; }

while [ "$(pending)" -gt 0 ]; do
  if [ "$clock" -ge "$TIMEOUT_SECONDS" ]; then
    for f in "$work/state/"*.json; do
      svc=$(jq -r .service "$f")
      [ "$(st "$svc" status)" = "done" ] && continue
      if [ -z "$(st "$svc" run_id)" ]; then
        finish "$svc" "" timeout false "no ${ROLLBACK_WORKFLOW} run showed up for the dispatch; check ${K8S_REPO} Actions"
      else
        finish "$svc" "" timeout false "timed out after ${TIMEOUT_SECONDS}s waiting for the rollback; it was NOT cancelled and may still finish"
      fi
    done
    break
  fi
  if ! listed=$(list_runs); then
    log "listing ${ROLLBACK_WORKFLOW} runs failed, retrying: $(cat "$work/err")"
    sleep "$POLL_SECONDS"
    clock=$((clock + POLL_SECONDS))
    continue
  fi
  for f in "$work/state/"*.json; do
    svc=$(jq -r .service "$f")
    [ "$(st "$svc" status)" = "done" ] && continue
    key=$(st "$svc" key)
    if [ -z "$(st "$svc" run_id)" ]; then
      # Newest run with our key that was not there before this dispatch.
      new=$(runs_for_key "$listed" "$key" | jq -c --slurpfile s "$f" '[.[] | select(.id as $id | ($s[0].known | index($id)) | not)] | first // empty')
      if [ -z "$new" ]; then
        if [ $((clock - $(st "$svc" dispatched_at))) -ge "$FIND_TIMEOUT_SECONDS" ]; then
          finish "$svc" "" not_found false "no ${ROLLBACK_WORKFLOW} run with key ${key} showed up within ${FIND_TIMEOUT_SECONDS}s of the dispatch; check ${K8S_REPO} Actions"
        fi
        continue
      fi
      st_set "$svc" '.run_id = ($r.id | tostring) | .run_url = $r.html_url | .known += [$r.id] | .status = "running"' --argjson r "$new"
      log "${svc}: following $(st "$svc" run_url)"
    fi
    run=$(jq -c --arg id "$(st "$svc" run_id)" '[.workflow_runs[]? | select((.id | tostring) == $id)] | first // empty' <<< "$listed")
    # Fell off the first page (many newer rollback runs): read it by id.
    [ -n "$run" ] || run=$(gh api "repos/${K8S_REPO}/actions/runs/$(st "$svc" run_id)" 2> /dev/null | jq -c 'select(.id != null)' 2> /dev/null || true)
    [ -n "$run" ] || continue
    [ "$(jq -r .status <<< "$run")" = completed ] || continue
    conclusion=$(jq -r '.conclusion // ""' <<< "$run")
    log "${svc}: run $(st "$svc" run_id) completed: ${conclusion}"
    if [ "$conclusion" = cancelled ]; then
      if [ "$(st "$svc" attempts)" -lt "$MAX_ATTEMPTS" ]; then
        log "${svc}: cancelled (displaced in the concurrency queue); dispatching again with the same key ${key}"
        dispatch "$svc" || finish "$svc" cancelled not_dispatched false "cancelled, and dispatching it again failed: $(tail -n 1 "$work/err")"
      else
        finish "$svc" cancelled cancelled false "cancelled ${MAX_ATTEMPTS} times; dispatch ${ROLLBACK_WORKFLOW} again with run_key ${key}"
      fi
      continue
    fi
    evaluate "$svc" "$conclusion"
  done
  if [ "$(pending)" -gt 0 ]; then
    sleep "$POLL_SECONDS"
    clock=$((clock + POLL_SECONDS))
  fi
done

results=$(jq -s -c 'map(del(.key, .status, .dispatched_at, .known))' "$work/state/"*.json)
bad=$(jq -r '[.[] | select(.ok | not) | "\(.service): \(.reason)"] | join("; ")' <<< "$results")
if [ -z "$bad" ]; then
  jq -nc --argjson r "$results" '{ok: true, needs_human: false, reason: "every service is back on its previous tag", results: $r}'
else
  jq -nc --argjson r "$results" --arg why "$bad" '{ok: false, needs_human: true, reason: $why, results: $r}'
fi
