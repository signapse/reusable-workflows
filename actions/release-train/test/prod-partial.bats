#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# Partial Deployment (SIG-2769): after a failed deploy-prod run or final check,
# prod-partial.sh waits for unfinished runs, re-reads the tags prod runs and
# says which dispatched services moved (partial), none, or unknown.
# $TMP/tags.json is what the prod-tags stub prints ($TMP/tags-fail makes it
# fail); $TMP/run-<id> holds "<status> <conclusion>" lines, one per poll (the
# last line repeats).
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub"
  export PATH="$TMP/stub:$PATH"
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
id=$(sed -E 's#.*/actions/runs/([0-9]+)$#\1#' <<< "$2")
n=$(cat "$TMP/polls-$id" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$TMP/polls-$id"
line=$(sed -n "${n}p" "$TMP/run-$id"); [ -n "$line" ] || line=$(tail -n 1 "$TMP/run-$id")
echo "$line"
EOS
  cat > "$TMP/stub/prod-tags" <<'EOS'
#!/usr/bin/env bash
[ -f "$TMP/tags-fail" ] && { echo "boom" >&2; exit 1; }
cat "$TMP/tags.json"
EOS
  cat > "$TMP/stub/sleep" <<'EOS'
#!/usr/bin/env bash
echo "$1" >> "$TMP/slept"
EOS
  chmod +x "$TMP/stub/"*
  export TAG=1.4.0 READ_TOKEN=r GH_TOKEN=p PROD_TAGS="$TMP/stub/prod-tags" POLL_SECONDS=10 WAIT_SECONDS=60
  export TO_DEPLOY='["api","ws"]'
}

teardown() { rm -rf "$TMP"; }

tags() { # tags <api-on-tag> <ws-on-tag>
  jq -nc --argjson a "$1" --argjson w "$2" '[{service: "api", on_tag: $a}, {service: "ws", on_tag: $w}, {service: "other", on_tag: true}]' > "$TMP/tags.json"
}
partial() { run "$S/prod-partial.sh"; }
field() { tail -n1 <<< "$output" | jq -r "$@"; }

@test "first service moved, second failed: partial, only dispatched services that run the tag" {
  tags true false
  export RUNS='[{"service":"api","run_id":1,"conclusion":"success"},{"service":"ws","run_id":2,"conclusion":"failure"}]'
  partial
  [ "$status" -eq 0 ]
  [ "$(field .state)" = partial ]
  [ "$(field -c .moved)" = '["api"]' ]
}

@test "a failed run that already pushed its tag counts as moved" {
  tags true true
  export RUNS='[{"service":"api","run_id":1,"conclusion":"success"},{"service":"ws","run_id":2,"conclusion":"failure"}]'
  partial
  [ "$(field .state)" = partial ]
  [ "$(field -c .moved)" = '["api","ws"]' ]
}

@test "nothing moved: none" {
  tags false false
  export RUNS='[{"service":"api","run_id":1,"conclusion":"failure"}]'
  partial
  [ "$(field .state)" = none ]
  [ "$(field -c .moved)" = '[]' ]
}

@test "a run still going is waited on; it pushes, then finishes: partial with it" {
  tags true true
  printf 'in_progress \nin_progress \ncompleted failure\n' > "$TMP/run-2"
  export RUNS='[{"service":"api","run_id":1,"conclusion":"success"},{"service":"ws","run_id":2,"conclusion":""}]'
  partial
  [ "$(field .state)" = partial ]
  [ "$(field -c .moved)" = '["api","ws"]' ]
  [ "$(wc -l < "$TMP/slept" | tr -d ' ')" -eq 2 ]
}

@test "a run still going after the wait, its service not on the tag: unknown, never guessed" {
  tags true false
  echo 'in_progress ' > "$TMP/run-2"
  export RUNS='[{"service":"api","run_id":1,"conclusion":"success"},{"service":"ws","run_id":2,"conclusion":""}]'
  partial
  [ "$(field .state)" = unknown ]
  [[ "$(field .reason)" == *"ws has not finished"* ]]
  [[ "$(field .reason)" == *"already on it: api"* ]]
}

@test "an uncorrelated dispatch (no run id) whose service is not on the tag: unknown" {
  tags false false
  export RUNS='[{"service":"api","run_id":"","conclusion":""}]'
  partial
  [ "$(field .state)" = unknown ]
  [ ! -f "$TMP/slept" ]
}

@test "tags unreadable after retries: unknown" {
  touch "$TMP/tags-fail"
  export RUNS='[{"service":"api","run_id":1,"conclusion":"success"}]' TAG_TRIES=3
  partial
  [ "$(field .state)" = unknown ]
  [[ "$(field .reason)" == *"could not read"* ]]
  [ "$(wc -l < "$TMP/slept" | tr -d ' ')" -eq 2 ]
}

@test "bad input exits 1" {
  TO_DEPLOY='nope' partial
  [ "$status" -eq 1 ]
}
