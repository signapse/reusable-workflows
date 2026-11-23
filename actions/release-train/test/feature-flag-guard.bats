#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# AC5 of SIG-2769: feature-flag-guard.sh reads each Feature ticket's PostHog
# flags (read-only) and fails when one is on in prod beyond the QA Cohort
# before a Rollout. A fake curl answers GET .../feature_flags/?search=sig-<n>-
# from $TMP/flags/<n>.json ({"results": [...]}); $TMP/posthog-fail makes it
# fail. Every request is logged to $TMP/calls.
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/flags"
  export PATH="$TMP/stub:$PATH"
  : > "$TMP/calls"
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
url=""; for a in "$@"; do case "$a" in https://*) url="$a" ;; -X) echo "write attempted" >> "$TMP/calls" ;; esac; done
echo "$url" >> "$TMP/calls"
[ -f "$TMP/posthog-fail" ] && { echo "curl: (22) The requested URL returned error: 401" >&2; exit 22; }
n=$(sed -E 's/.*search=sig-([0-9]+)-.*/\1/' <<< "$url")
# page 2 of a search is $TMP/flags/<n>.json.2, linked by "next" on page 1.
if [[ "$url" == *"&page=2"* ]]; then cat "$TMP/flags/$n.json.2"
elif [ -f "$TMP/flags/$n.json" ]; then cat "$TMP/flags/$n.json"; else echo '{"results":[]}'; fi
EOS
  chmod +x "$TMP/stub/"*
  export POSTHOG_API_KEY=phx_read QA_COHORT_ID=42
}

teardown() { rm -rf "$TMP"; }

# flag <n> <key> <prod-percent|null> [extra-group-json]: the docs/POSTHOG-FLAGS.md template.
flag() {
  jq -nc --arg k "$2" --argjson p "$3" --argjson x "${4:-null}" '{results: [{key: $k, active: true, deleted: false,
    filters: {groups: ([
      {properties: [{key: "environment", type: "person", operator: "exact", value: ["dev", "development", "staging"]}], rollout_percentage: 100},
      {properties: [{key: "id", type: "cohort", operator: "in", value: 42}], rollout_percentage: 100},
      {properties: [{key: "environment", type: "person", operator: "exact", value: ["prod", "production"]}], rollout_percentage: $p}]
      + (if $x then [$x] else [] end))}}]}' > "$TMP/flags/$1.json"
}

tickets() {
  cat <<'EOF'
[{"id": "SIG-1", "found": true, "state": "On Staging", "labels": ["Feature", "Staging Passed"]},
 {"id": "SIG-2", "found": true, "state": "On Staging", "labels": ["Bug"]},
 {"id": "SIG-3", "found": true, "state": "Rolling Out", "labels": ["Feature"]},
 {"id": "SIG-9", "found": false, "state": null, "labels": []}]
EOF
}

guard() { run "$S/feature-flag-guard.sh" < <(tickets); }
field() { tail -n1 <<< "$output" | jq -r "$@"; }

@test "AC5: a Feature flag at 0% in prod (QA Cohort only) passes; only Feature tickets are read, nothing is written" {
  flag 1 sig-1-new-thing 0
  guard
  [ "$status" -eq 0 ]
  [ "$(field .ok)" = true ]
  [ "$(field -c '[.checked[].flag]')" = '["sig-1-new-thing"]' ]
  [ "$(grep -c search "$TMP/calls")" = 1 ]
  grep -q 'https://eu.posthog.com/api/projects/256388/feature_flags/?search=sig-1-' "$TMP/calls"
  [ "$(grep -c 'write attempted' "$TMP/calls")" = 0 ]
}

@test "AC5: the prod condition above 0% before any Rollout fails loudly" {
  flag 1 sig-1-new-thing 10
  guard
  [ "$status" -ne 0 ]
  [ "$(field .ok)" = false ]
  [[ "$(field '.errors[0]')" == *"sig-1-new-thing is on in prod beyond the QA Cohort"*"condition 2 at 10%"* ]]
}

@test "a null rollout percentage counts as 100%" {
  flag 1 sig-1-new-thing null
  guard
  [ "$status" -ne 0 ]
  [[ "$(field '.errors[0]')" == *"at 100%"* ]]
}

@test "a hand-added catch-all condition fails too" {
  flag 1 sig-1-new-thing 0 '{"properties": [], "rollout_percentage": 5}'
  guard
  [ "$status" -ne 0 ]
  [[ "$(field '.errors[0]')" == *"condition 3 at 5%"* ]]
}

@test "a cohort condition for another cohort (not the QA Cohort) fails" {
  flag 1 sig-1-new-thing 0 '{"properties": [{"key": "id", "type": "cohort", "operator": "in", "value": 7}], "rollout_percentage": 100}'
  guard
  [ "$status" -ne 0 ]
  [ "$(field -c '.checked[0].offending')" = '[{"index":3,"rollout_percentage":100}]' ]
}

@test "a leaking flag on a later page of the search fails" {
  flag 1 sig-1-safe 0
  jq -c '. + {next: "https://eu.posthog.com/api/projects/256388/feature_flags/?search=sig-1-&limit=100&page=2"}' \
    "$TMP/flags/1.json" > "$TMP/f" && mv "$TMP/f" "$TMP/flags/1.json"
  jq -nc '{results: [{key: "sig-1-leak", active: true, deleted: false,
    filters: {groups: [{properties: [], rollout_percentage: 50}]}}]}' > "$TMP/flags/1.json.2"
  guard
  [ "$status" -eq 1 ]
  [[ "$(field '.errors[0]')" == *"sig-1-leak"* ]]
}

@test "no QA Cohort id with a Feature ticket to check fails instead of trusting any cohort" {
  flag 1 sig-1-new-thing 0
  QA_COHORT_ID="" guard
  [ "$status" -ne 0 ]
  [[ "$(field '.errors[0]')" == *qa_cohort_id* ]]
}

@test "a Feature ticket without a flag fails (ADR 0004)" {
  guard
  [ "$status" -ne 0 ]
  [[ "$(field '.errors[0]')" == *"SIG-1 is a Feature ticket but has no PostHog flag sig-1-"* ]]
}

@test "flags of other tickets sharing the search prefix are ignored" {
  flag 1 sig-12-other 50
  guard
  [ "$status" -ne 0 ]
  [[ "$(field '.errors[0]')" == *"no PostHog flag"* ]]
}

@test "a ticket whose Rollout started is skipped" {
  flag 1 sig-1-new-thing 0
  guard
  [ "$(field -c '.skipped')" = '[{"ticket":"SIG-3","reason":"Rollout started (Rolling Out)"}]' ]
}

@test "PostHog unreachable fails instead of passing silently" {
  flag 1 sig-1-new-thing 0
  touch "$TMP/posthog-fail"
  guard
  [ "$status" -ne 0 ]
  [[ "$(field '.errors[0]')" == *"lookup failed"* ]]
}

@test "no key with a Feature ticket to check fails" {
  unset POSTHOG_API_KEY
  guard
  [ "$status" -ne 0 ]
  [[ "$(field '.errors[0]')" == *"POSTHOG_API_KEY is not set"* ]]
}

@test "no Feature tickets: passes without a key or a PostHog call" {
  unset POSTHOG_API_KEY
  run "$S/feature-flag-guard.sh" <<< '[{"id": "SIG-2", "found": true, "state": "On Staging", "labels": ["Bug"]}]'
  [ "$status" -eq 0 ]
  [ ! -s "$TMP/calls" ]
}
