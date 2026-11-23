#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# Prod deploy dispatch (SIG-2769, AC1): prod-deploy.sh dispatches
# signapse-core-k8s deploy-prod.yml per service, finds the run and waits.
# The gh stub models that repo's Actions, with switches in $TMP:
#   details-ok     the dispatch API accepts return_run_details and returns the run id
#   key-ok         deploy-prod.yml has a run_key input (else 422 when sent)
#   run-name       its runs are titled "Deploy <svc> [<run_key>]" (else "Deploy to prod")
#   extra-run      each dispatch also makes someone else's plain run appear
#   no-run         a dispatch starts no visible run
#   dispatch-403   every dispatch fails with 403
#   conclusion-<id>  conclusion of run <id> (default success; never = keeps running)
# Runs get ids 501, 502, ... in order; $TMP/runs.json lists them, newest first.
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
[ "$1" = api ] || { echo "gh stub: unhandled $*" >&2; exit 1; }
shift
add_run() { # add_run <title>
  n=$(( $(jq length "$TMP/runs.json") + 501 ))
  jq -c --arg t "$1" --argjson n "$n" '[{id: $n, display_title: $t, head_branch: "main",
    html_url: "https://github.com/signapse/signapse-core-k8s/actions/runs/\($n)"}] + .' \
    "$TMP/runs.json" > "$TMP/r" && mv "$TMP/r" "$TMP/runs.json"
  echo "$n"
}
if [ "$1" = -X ]; then
  body=$(cat)
  [ -f "$TMP/dispatch-403" ] && { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
  [ -f "$TMP/dispatch-502" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
  if jq -e '.inputs.run_key' <<< "$body" > /dev/null && [ ! -f "$TMP/key-ok" ]; then
    echo 'gh: Unexpected inputs provided: ["run_key"] (HTTP 422)' >&2; exit 1
  fi
  if jq -e '.return_run_details' <<< "$body" > /dev/null && [ ! -f "$TMP/details-ok" ]; then
    echo 'gh: Invalid request. "return_run_details" is not a permitted key. (HTTP 422)' >&2; exit 1
  fi
  echo "$body" >> "$TMP/dispatched"
  [ -f "$TMP/extra-run" ] && add_run "Deploy to prod" > /dev/null
  [ -f "$TMP/no-run" ] && exit 0
  svc=$(jq -r .inputs.service <<< "$body"); key=$(jq -r '.inputs.run_key // ""' <<< "$body")
  if [ -f "$TMP/run-name" ]; then id=$(add_run "Deploy $svc [$key]"); else id=$(add_run "Deploy to prod"); fi
  if jq -e '.return_run_details' <<< "$body" > /dev/null; then
    jq -nc --argjson id "$id" '{workflow_run_id: $id, run_url: "https://api.github.com/x/\($id)"}'
  fi
  exit 0
fi
case "$1" in
  */workflows/*/runs\?*) jq -c '{workflow_runs: .}' "$TMP/runs.json" ;;
  */actions/runs/*)
    id="${1##*/}"; c=$(cat "$TMP/conclusion-$id" 2>/dev/null || echo success)
    if [ "$c" = never ]; then echo '{"status":"in_progress","conclusion":null}'
    else jq -nc --arg c "$c" '{status: "completed", conclusion: $c}'; fi ;;
  *) echo "gh stub: unhandled api $1" >&2; exit 1 ;;
esac
EOS
  cat > "$TMP/stub/sleep" <<'EOS'
#!/usr/bin/env bash
echo "$1" >> "$TMP/slept"
EOS
  chmod +x "$TMP/stub/"*
  export GH_TOKEN=x TAG=1.4.0 SERVICES='["signstream-api"]' RUN_KEY=sign-stream-api-42-1-prod
  export POLL_SECONDS=10 TIMEOUT_SECONDS=60 FIND_TIMEOUT_SECONDS=30
}

teardown() { rm -rf "$TMP"; }

deploy() { run "$S/prod-deploy.sh"; }
field() { tail -n1 <<< "$output" | jq -r "$@"; }

@test "AC1: dispatches deploy-prod on main with the release tag, follows the run the API returned" {
  touch "$TMP/details-ok" "$TMP/key-ok"
  deploy
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = true ]
  [ "$(field '.runs[0].correlated_by')" = dispatch_response ]
  [ "$(field '.runs[0].run_id')" = 501 ]
  [ "$(field '.runs[0].run_url')" = https://github.com/signapse/signapse-core-k8s/actions/runs/501 ]
  [ "$(field '.runs[0].conclusion')" = success ]
  [ "$(jq -c '{ref, inputs}' "$TMP/dispatched")" = '{"ref":"main","inputs":{"service":"signstream-api","tag":"1.4.0","run_key":"sign-stream-api-42-1-prod-signstream-api"}}' ]
}

@test "today's deploy-prod (no run_key input, no run id): 422s start nothing, then the only new run is ours" {
  echo '[{"id": 400, "display_title": "Deploy to prod", "head_branch": "main", "html_url": "old"}]' > "$TMP/runs.json"
  deploy
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = true ]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" = 1 ]
  [ "$(jq -c . "$TMP/dispatched")" = '{"ref":"main","inputs":{"service":"signstream-api","tag":"1.4.0"}}' ]
  [ "$(field '.runs[0].run_id')" = 502 ]
  [ "$(field '.runs[0].correlated_by')" = only_new_run ]
}

@test "once deploy-prod takes run_key and shows it in run-name, the run is found by run_key" {
  touch "$TMP/key-ok" "$TMP/run-name" "$TMP/extra-run"
  deploy
  [ "$(field .ok)" = true ]
  [ "$(field '.runs[0].correlated_by')" = run_key ]
  [ "$(field '.runs[0].run_key')" = sign-stream-api-42-1-prod-signstream-api ]
}

@test "two new plain runs: fails as ambiguous instead of guessing" {
  touch "$TMP/extra-run"
  deploy
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = false ]
  [[ "$(field .reason)" == *"could not tell which new deploy-prod.yml run is ours"* ]]
}

@test "services deploy one at a time, each with its own run key" {
  touch "$TMP/details-ok" "$TMP/key-ok"
  export SERVICES='["signstream-api","signstream-websocket"]'
  deploy
  [ "$(field .ok)" = true ]
  [ "$(field -c '[.runs[].service]')" = '["signstream-api","signstream-websocket"]' ]
  [ "$(field '.runs[1].run_key')" = sign-stream-api-42-1-prod-signstream-websocket ]
}

@test "a failed deploy-prod run fails the step and stops before the next service" {
  touch "$TMP/details-ok"
  echo failure > "$TMP/conclusion-501"
  export SERVICES='["signstream-api","signstream-websocket"]'
  deploy
  [ "$(field .ok)" = false ]
  [[ "$(field .reason)" == *"concluded failure"* ]]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" = 1 ]
}

@test "a cancelled run is a failure, never re-dispatched (it may have been replaced by a rollback)" {
  touch "$TMP/details-ok"
  echo cancelled > "$TMP/conclusion-501"
  deploy
  [ "$(field .ok)" = false ]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" = 1 ]
}

@test "timeout: reports the run as still going, does not cancel it" {
  touch "$TMP/details-ok"
  echo never > "$TMP/conclusion-501"
  deploy
  [ "$(field .ok)" = false ]
  [[ "$(field .reason)" == *"NOT cancelled"* ]]
  [ "$(field '.runs[0].run_id')" = 501 ]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" = 1 ]
}

@test "a dispatch the token may not make fails without retrying" {
  touch "$TMP/dispatch-403"
  deploy
  [ "$(field .ok)" = false ]
  [[ "$(field .reason)" == *"HTTP 403"* ]]
  [ ! -s "$TMP/dispatched" ]
  [ "$(field -c .runs)" = '[]' ]
}

@test "a 5xx on the dispatch may have started a run: the service is recorded without a run id" {
  touch "$TMP/dispatch-502"
  deploy
  [ "$(field .ok)" = false ]
  [ "$(field -c '[.runs[] | {service, run_id}]')" = '[{"service":"signstream-api","run_id":""}]' ]
}

@test "no run shows up: fails after the find timeout" {
  touch "$TMP/no-run"
  deploy
  [ "$(field .ok)" = false ]
  [[ "$(field .reason)" == *"showed up"* ]]
}

@test "bad input is refused before any dispatch" {
  export TAG='bad tag'
  deploy
  [ "$status" -ne 0 ]
  [ ! -s "$TMP/dispatched" ]
}
