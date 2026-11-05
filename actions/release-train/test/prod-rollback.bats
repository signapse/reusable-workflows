#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# Automatic rollback (SIG-2771, AC1, AC5): prod-rollback.sh dispatches
# signapse-core-k8s rollback.yml per service, follows the run by run_key,
# re-dispatches a cancelled one with the same key, reads rollback.json and
# checks the restored tag against the tag prod ran before the Deployment.
#
# The gh stub models rollback.yml. $TMP/plan-<svc> has one line per dispatch of
# that service, "<conclusion> <result> <restored>" (default "success success
# 1.3.0"); conclusion `never` keeps the run going, result `none` uploads no
# artifact. Runs get ids 701, 702, ... and the title rollback.yml's run-name
# gives: "Rollback <svc> (<env>) [<run_key>]". $TMP/seed.json pre-loads runs.
# Accepted dispatch bodies go to $TMP/dispatched (one JSON per line).
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub"
  export PATH="$TMP/stub:$PATH"
  echo '[]' > "$TMP/runs.json"
  : > "$TMP/dispatched"
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = run ] && [ "$2" = download ]; then
  id="$3"; dir=""
  shift 3
  while [ $# -gt 0 ]; do case "$1" in -D) dir="$2"; shift 2 ;; *) shift ;; esac; done
  run=$(jq -c --argjson id "$id" '.[] | select(.id == $id)' "$TMP/runs.json")
  [ "$(jq -r ._result <<< "$run")" != none ] || { echo "no artifact matches any of the names or patterns provided" >&2; exit 1; }
  mkdir -p "$dir"
  jq '{service: ._svc, environment: "prod", run_key: ._key, result: ._result, restored: ._restored,
       replaced: "1.4.0", changed: true, restored_commit: "abc1234", restored_commit_date: "2026-11-01T10:00:00Z"}' \
    <<< "$run" > "$dir/rollback.json"
  exit 0
fi
[ "$1" = api ] || { echo "gh stub: unhandled $*" >&2; exit 1; }
shift
if [ "$1" = -X ]; then
  body=$(cat)
  [ -f "$TMP/dispatch-403" ] && { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
  echo "$body" >> "$TMP/dispatched"
  svc=$(jq -r .inputs.service <<< "$body"); key=$(jq -r .inputs.run_key <<< "$body"); env=$(jq -r .inputs.environment <<< "$body")
  k=$(jq -r --arg s "$svc" '[.[] | select(._svc == $s)] | length' "$TMP/runs.json")
  line=$(sed -n "$((k + 1))p" "$TMP/plan-$svc" 2>/dev/null || true)
  read -r c r t <<< "${line:-success success 1.3.0}"
  n=$(( $(jq length "$TMP/runs.json") + 701 ))
  jq -c --arg t "Rollback $svc ($env) [$key]" --argjson n "$n" --arg c "$c" --arg r "$r" --arg rt "$t" --arg s "$svc" --arg k "$key" \
    '. + [{id: $n, display_title: $t, html_url: "https://github.com/signapse/signapse-core-k8s/actions/runs/\($n)",
      status: (if $c == "never" then "in_progress" else "completed" end), conclusion: (if $c == "never" then null else $c end),
      _svc: $s, _key: $k, _result: $r, _restored: $rt}]' "$TMP/runs.json" > "$TMP/r" && mv "$TMP/r" "$TMP/runs.json"
  exit 0
fi
case "$1" in
  */workflows/rollback.yml/runs\?*)
    [ -f "$TMP/no-workflow" ] && { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    # $TMP/page-size: only that many newest runs are listed (pagination).
    jq -c --argjson n "$(cat "$TMP/page-size" 2>/dev/null || echo 100)" '{workflow_runs: (. | reverse | .[:$n])}' "$TMP/runs.json" ;;
  */actions/runs/*)
    id="${1##*/}"
    jq -c --argjson id "$id" '.[] | select(.id == $id)' "$TMP/runs.json" ;;
  *) echo "gh stub: unhandled api $1" >&2; exit 1 ;;
esac
EOS
  cat > "$TMP/stub/sleep" <<'EOS'
#!/usr/bin/env bash
echo "$1" >> "$TMP/slept"
EOS
  chmod +x "$TMP/stub/"*
  export GH_TOKEN=x SERVICES='["signstream-api"]' PREVIOUS_TAGS='{"signstream-api":"1.3.0"}'
  export DEPLOY_RUN_KEY=sign-stream-api-42-1-prod POLL_SECONDS=10 TIMEOUT_SECONDS=60 FIND_TIMEOUT_SECONDS=30
}

teardown() { rm -rf "$TMP"; }

rollback() { run "$S/prod-rollback.sh"; }
field() { tail -n1 <<< "$output" | jq -r "$@"; }

@test "AC1: dispatches rollback.yml on main with a key derived from the deploy run key, restored == previous tag" {
  rollback
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = true ]
  [ "$(field .needs_human)" = false ]
  [ "$(jq -c . "$TMP/dispatched")" = '{"ref":"main","inputs":{"service":"signstream-api","environment":"prod","run_key":"sign-stream-api-42-1-prod-signstream-api-rollback"}}' ]
  [ "$(field '.results[0].run_url')" = https://github.com/signapse/signapse-core-k8s/actions/runs/701 ]
  [ "$(field '.results[0].result')" = success ]
  [ "$(field '.results[0].restored')" = 1.3.0 ]
  [ "$(field '.results[0].expected')" = 1.3.0 ]
  [ "$(field '.results[0].restored_commit')" = abc1234 ]
}

@test "AC1: a restored tag other than the one prod ran before is a failure" {
  echo "success success 1.2.0" > "$TMP/plan-signstream-api"
  rollback
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = false ]
  [ "$(field .needs_human)" = true ]
  [[ "$(field '.results[0].reason')" == *"restored 1.2.0, but prod ran 1.3.0 before"* ]]
}

@test "two services roll back in parallel: both dispatched before any wait" {
  export SERVICES='["signstream-api","signstream-websocket"]' PREVIOUS_TAGS='{"signstream-api":"1.3.0","signstream-websocket":"1.3.0"}'
  printf 'never x x\n' > "$TMP/plan-signstream-api"
  export TIMEOUT_SECONDS=20
  rollback
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" = 2 ]
  [ "$(field '[.results[] | {service, ok}] | map("\(.service)=\(.ok)") | join(",")')" = "signstream-api=false,signstream-websocket=true" ]
  [[ "$(field '.results[0].reason')" == *"NOT cancelled"* ]]
}

@test "cancelled: dispatched again with the SAME run_key, then succeeds" {
  printf 'cancelled x x\nsuccess success 1.3.0\n' > "$TMP/plan-signstream-api"
  rollback
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = true ]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" = 2 ]
  [ "$(jq -r .inputs.run_key "$TMP/dispatched" | sort -u)" = sign-stream-api-42-1-prod-signstream-api-rollback ]
  [ "$(field '.results[0].attempts')" = 2 ]
  [ "$(field '.results[0].run_id')" = 702 ]
}

@test "cancelled every time: bounded by MAX_ATTEMPTS, then a failure" {
  printf 'cancelled x x\ncancelled x x\ncancelled x x\ncancelled x x\n' > "$TMP/plan-signstream-api"
  export MAX_ATTEMPTS=3
  rollback
  [ "$(field .ok)" = false ]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" = 3 ]
  [ "$(field '.results[0].result')" = cancelled ]
  [[ "$(field '.results[0].reason')" == *"cancelled 3 times"* ]]
}

@test "exit 4 (needs_human): not re-dispatched, needs a human" {
  echo "failure needs_human " > "$TMP/plan-signstream-api"
  rollback
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = false ]
  [ "$(field .needs_human)" = true ]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" = 1 ]
  [ "$(field '.results[0].result')" = needs_human ]
  [[ "$(field '.results[0].reason')" == *"exit 4"* ]]
}

@test "exit 3 (no previous tag): needs a human" {
  echo "failure no_previous_tag " > "$TMP/plan-signstream-api"
  rollback
  [ "$(field .ok)" = false ]
  [ "$(field '.results[0].result')" = no_previous_tag ]
  [[ "$(field '.reason')" == *"no previous tag"* ]]
}

@test "rollback run failure (e.g. Flux suspended) is a failure, not retried" {
  echo "failure failed 1.3.0" > "$TMP/plan-signstream-api"
  rollback
  [ "$(field .ok)" = false ]
  [ "$(field .needs_human)" = true ]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" = 1 ]
  [ "$(field '.results[0].result')" = failed ]
}

@test "a run without rollback.json cannot be verified: failure" {
  echo "success none x" > "$TMP/plan-signstream-api"
  rollback
  [ "$(field .ok)" = false ]
  [[ "$(field '.results[0].reason')" == *"no readable rollback.json"* ]]
}

@test "dispatch refused (403): failure naming it" {
  touch "$TMP/dispatch-403"
  rollback
  [ "$(field .ok)" = false ]
  [ "$(field '.results[0].result')" = not_dispatched ]
  [[ "$(field '.results[0].reason')" == *"HTTP 403"* ]]
}

@test "rollback.yml missing on signapse-core-k8s (404): every service fails naming it, nothing dispatched" {
  touch "$TMP/no-workflow"
  export SERVICES='["signstream-api","signstream-websocket"]'
  rollback
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = false ]
  [ "$(field .needs_human)" = true ]
  [[ "$(field .reason)" == *"rollback.yml does not exist on signapse/signapse-core-k8s"* ]]
  [ "$(field '[.results[].result] | unique | join(",")')" = missing_workflow ]
  [ "$(field '[.results[].service] | join(",")')" = signstream-api,signstream-websocket ]
  [ "$(field '.results[0].expected')" = 1.3.0 ]
  [ ! -s "$TMP/dispatched" ]
}

@test "any other listing failure still exits 1" {
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
echo 'gh: Server Error (HTTP 502)' >&2; exit 1
EOS
  rollback
  [ "$status" -eq 1 ]
}

@test "re-run: an earlier attempt's successful rollback is reused, nothing dispatched" {
  "$S/prod-rollback.sh" > /dev/null 2>&1
  : > "$TMP/dispatched"
  rollback
  [ "$(field .ok)" = true ]
  [ ! -s "$TMP/dispatched" ]
  [ "$(field '.results[0].run_id')" = 701 ]
}

@test "re-run: an earlier failed rollback is dispatched again with the same key" {
  echo "failure failed 1.3.0" > "$TMP/plan-signstream-api"
  echo "success success 1.3.0" >> "$TMP/plan-signstream-api"
  "$S/prod-rollback.sh" > /dev/null 2>&1
  rollback
  [ "$(field .ok)" = true ]
  [ "$(field '.results[0].run_id')" = 702 ]
  [ "$(jq -r .inputs.run_key "$TMP/dispatched" | sort -u | wc -l | tr -d ' ')" = 1 ]
}

@test "no previous tag recorded by the Deployment: ok only if prod left the failed tag" {
  export PREVIOUS_TAGS='{}'
  RELEASE_TAG=1.4.0 rollback
  [ "$(field .ok)" = true ]
  [[ "$(field '.results[0].reason')" == *"not 1.4.0; the Deployment recorded no previous tag"* ]]
}

@test "no previous tag and nothing to compare against: needs a human, not a success" {
  export PREVIOUS_TAGS='{}'
  rollback
  [ "$(field .ok)" = false ]
  [ "$(field .needs_human)" = true ]
  [[ "$(field '.results[0].reason')" == *"needs a human"* ]]
}

@test "bad input exits 1" {
  SERVICES='[]' rollback
  [ "$status" -eq 1 ]
  SERVICES='["Bad Name"]' rollback
  [ "$status" -eq 1 ]
}

@test "re-run: an earlier success is reused even when a later attempt with the key failed" {
  printf 'success success 1.3.0\nfailure failed 1.3.0\n' > "$TMP/plan-signstream-api"
  "$S/prod-rollback.sh" > /dev/null 2>&1                     # run 701: success
  body='{"ref":"main","inputs":{"service":"signstream-api","environment":"prod","run_key":"sign-stream-api-42-1-prod-signstream-api-rollback"}}'
  gh api -X POST x <<< "$body"                               # run 702: a later failed attempt
  : > "$TMP/dispatched"
  rollback
  [ "$(field .ok)" = true ]
  [ "$(field '.results[0].run_id')" = 701 ]
  [ ! -s "$TMP/dispatched" ]
}

@test "a service no longer on the release tag (newer deployment after the smoke) is not rolled back" {
  export RELEASE_TAG=1.4.0 SERVICES='["signstream-api","signstream-websocket"]'
  export PREVIOUS_TAGS='{"signstream-api":"1.3.0","signstream-websocket":"1.3.0"}'
  export CURRENT_TAGS='[{"service":"signstream-api","current_tag":"1.5.0","on_tag":false},{"service":"signstream-websocket","current_tag":"1.4.0","on_tag":true}]'
  rollback
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = false ]
  [ "$(field '.results[] | select(.service == "signstream-api") | .result')" = not_current ]
  [[ "$(field '.results[] | select(.service == "signstream-api") | .reason')" == *"prod runs 1.5.0, not 1.4.0"* ]]
  [ "$(field '.results[] | select(.service == "signstream-websocket") | .ok')" = true ]
  [ "$(jq -r .inputs.service "$TMP/dispatched")" = signstream-websocket ]
}

@test "a followed run that fell off the first page of runs is read by id, not timed out" {
  echo "never x 1.3.0" > "$TMP/plan-signstream-api"
  echo "success success 1.3.0" > "$TMP/plan-signstream-websocket"
  export SERVICES='["signstream-api","signstream-websocket"]'
  export PREVIOUS_TAGS='{"signstream-api":"1.3.0","signstream-websocket":"1.3.0"}'
  # Both runs are found on the first listing. Then newer runs push 701 off
  # the page (page size 1 from the first sleep on); it completes and is read by id.
  cat > "$TMP/stub/sleep" <<'EOS'
#!/usr/bin/env bash
echo "$1" >> "$TMP/slept"
echo 1 > "$TMP/page-size"
jq -c 'map(if .id == 701 then .status = "completed" | .conclusion = "success" | ._result = "success" else . end)' "$TMP/runs.json" > "$TMP/r" && mv "$TMP/r" "$TMP/runs.json"
EOS
  chmod +x "$TMP/stub/sleep"
  rollback
  [ "$(field .ok)" = true ]
  [ "$(field '.results[] | select(.service == "signstream-api") | .result')" = success ]
}
