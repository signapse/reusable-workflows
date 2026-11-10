#!/usr/bin/env bats
load 'helpers/load'

PAYLOAD="$BATS_TEST_DIRNAME/../scripts/posthog-flag-payload.sh"
CHECK="$BATS_TEST_DIRNAME/../scripts/posthog-flag-check.sh"

setup() {
  TMP="$(mktemp -d)"
  export QA_COHORT_ID=4242
}

teardown() { rm -rf "$TMP"; }

# --- posthog-flag-payload.sh ------------------------------------------------

@test "payload: key is sig-<n>-<slug>, area tag dropped, cut on a word boundary" {
  run "$PAYLOAD" SIG-2749 "[Platform] PostHog QA Cohort and environment-targeted flag template"
  [ "$status" -eq 0 ]
  [ "$(jq -r .key <<< "$output")" = "sig-2749-posthog-qa-cohort-and-environment" ]
}

@test "payload: lowercase ticket id and short title" {
  run "$PAYLOAD" sig-7 "Dark mode!"
  [ "$status" -eq 0 ]
  [ "$(jq -r .key <<< "$output")" = "sig-7-dark-mode" ]
}

@test "payload: a single word longer than the limit is hard-cut" {
  run "$PAYLOAD" SIG-1 "$(printf 'a%.0s' {1..60})"
  [ "$status" -eq 0 ]
  key=$(jq -r .key <<< "$output")
  [ "$key" = "sig-1-$(printf 'a%.0s' {1..40})" ]
}

@test "payload: three conditions in the standard order and percentages" {
  run "$PAYLOAD" SIG-10 "Thing" "https://linear.app/signapse/issue/SIG-10"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.filters.groups[].rollout_percentage]' <<< "$output")" = "[100,100,0]" ]
  [ "$(jq -c '.filters.groups[0].properties[0] | [.key,.type,.operator,.value]' <<< "$output")" \
    = '["environment","person","exact",["dev","development","staging"]]' ]
  [ "$(jq -c '.filters.groups[1].properties[0] | [.key,.type,.operator,.value]' <<< "$output")" \
    = '["id","cohort","in",4242]' ]
  [ "$(jq -c '.filters.groups[2].properties[0] | [.key,.type,.operator,.value]' <<< "$output")" \
    = '["environment","person","exact",["prod","production"]]' ]
  # No catch-all: every condition names an environment or the cohort.
  [ "$(jq '[.filters.groups[] | select(.properties == [])] | length' <<< "$output")" -eq 0 ]
}

@test "payload: person-aggregated, active, no experience continuity" {
  run "$PAYLOAD" SIG-10 "Thing"
  [ "$(jq -c '[.active, .ensure_experience_continuity, .filters.aggregation_group_type_index]' <<< "$output")" \
    = "[true,false,null]" ]
}

@test "payload: name carries ticket id and url" {
  run "$PAYLOAD" SIG-10 "Thing" "https://linear.app/x/SIG-10"
  name=$(jq -r .name <<< "$output")
  [[ "$name" == "SIG-10: Thing (https://linear.app/x/SIG-10)."* ]]
}

@test "payload: dev project (275880) flag has the same key and one 100% condition for everyone" {
  prod=$("$PAYLOAD" SIG-10 "Thing" "https://linear.app/signapse/issue/SIG-10")
  POSTHOG_PROJECT=dev QA_COHORT_ID="" run "$PAYLOAD" SIG-10 "Thing" "https://linear.app/signapse/issue/SIG-10"
  [ "$status" -eq 0 ]
  [ "$(jq -r .key <<< "$output")" = "$(jq -r .key <<< "$prod")" ]
  [ "$(jq -r .name <<< "$output")" = "$(jq -r .name <<< "$prod")" ]
  [ "$(jq -c '.filters.groups' <<< "$output")" = '[{"properties":[],"rollout_percentage":100,"variant":null}]' ]
  [ "$(jq -r .filters.aggregation_group_type_index <<< "$output")" = null ]
  [ "$(jq -r .active <<< "$output")" = true ]
}

@test "payload: rejects an unknown POSTHOG_PROJECT" {
  POSTHOG_PROJECT=staging run "$PAYLOAD" SIG-10 "Thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"prod or dev"* ]]
}

@test "payload: rejects a malformed ticket id" {
  run "$PAYLOAD" LIV-10 "Thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SIG-123"* ]]
}

@test "payload: rejects a missing or non-numeric QA_COHORT_ID" {
  QA_COHORT_ID="" run "$PAYLOAD" SIG-10 "Thing"
  [ "$status" -ne 0 ]
  QA_COHORT_ID="qa" run "$PAYLOAD" SIG-10 "Thing"
  [ "$status" -ne 0 ]
}

@test "payload: rejects a title with no letters or digits" {
  run "$PAYLOAD" SIG-10 "[Platform] !!!"
  [ "$status" -ne 0 ]
}

# --- posthog-flag-check.sh --------------------------------------------------
# A fake curl answers /flags the way the standard setup would: on in
# dev/development/staging, on for the QA id, and in prod/production on for
# synthetic ids whose trailing number mod 100 is below STUB_PERCENT.
# STUB_CATCH_ALL=1 imitates the rejected catch-all prod condition.
# STUB_PROD_ENVS lists the values in the prod condition (default "prod production").
# STUB_FAIL_ON="<distinct_id> <environment>" fails only that one request.

stub_curl() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
body=""
while [ $# -gt 0 ]; do
  [ "$1" = "--data-binary" ] && body="$2"
  shift
done
[ -n "${STUB_FAIL:-}" ] && exit 22
if [ -n "${STUB_MISSING:-}" ]; then echo '{"flags":{}}'; exit 0; fi
id=$(jq -r .distinct_id <<< "$body")
env=$(jq -r .person_properties.environment <<< "$body")
[ -n "${STUB_FAIL_ON:-}" ] && [ "$STUB_FAIL_ON" = "$id $env" ] && exit 22
on=false
case "$env" in dev|development|staging) on=true ;; esac
[ "$id" = "qa-user" ] && on=true
prod=false
if [ -n "$env" ] && [[ " ${STUB_PROD_ENVS:-prod production} " == *" $env "* ]]; then
  prod=true
else
  case "$env" in prod|production|dev|development|staging) ;; *) [ -n "${STUB_CATCH_ALL:-}" ] && prod=true ;; esac
fi
if [ "$prod" = true ]; then
  if [[ "$id" =~ -([0-9]+)$ ]] && [ $(( BASH_REMATCH[1] % 100 )) -lt "${STUB_PERCENT:-0}" ]; then on=true; fi
  if [ "$id" = "other-user" ] && [ "${STUB_PERCENT:-0}" -ge 100 ]; then on=true; fi
fi
jq -nc --arg k "$STUB_KEY" --argjson on "$on" '{flags: {($k): {key: $k, enabled: $on}}}'
EOF
  chmod +x "$TMP/bin/curl"
  export PATH="$TMP/bin:$PATH"
  export STUB_KEY=sig-1-thing POSTHOG_PROJECT_TOKEN=phc_test QA_DISTINCT_ID=qa-user OTHER_DISTINCT_ID=other-user
}

@test "check: dark flag at 0% passes AC2 and AC3" {
  stub_curl
  STUB_PERCENT=0 PROD_PERCENT=0 SAMPLE=20 run "$CHECK" sig-1-thing
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS AC2 prod at 0%, non-cohort user: false"* ]]
  [[ "$output" == *"PASS AC2 production at 0%, non-cohort user: false"* ]]
  [[ "$output" == *"PASS AC3 prod, QA Cohort user: true"* ]]
  [[ "$output" == *"0/20 synthetic"* ]]
}

@test "check: 10% rollout lands inside the accepted band" {
  stub_curl
  STUB_PERCENT=10 PROD_PERCENT=10 SAMPLE=100 run "$CHECK" sig-1-thing
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS AC4 prod at 10%, 10/100"* ]]
}

@test "check: flag left at 0% fails when 10% was expected" {
  stub_curl
  STUB_PERCENT=0 PROD_PERCENT=10 SAMPLE=100 run "$CHECK" sig-1-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL AC4 prod at 10%, 0/100"* ]]
}

@test "check: flag at 100% passes" {
  stub_curl
  STUB_PERCENT=100 PROD_PERCENT=100 SAMPLE=10 run "$CHECK" sig-1-thing
  [ "$status" -eq 0 ]
  [[ "$output" == *"10/10 synthetic"* ]]
}

@test "check: a prod condition without the legacy production value fails at 100%" {
  stub_curl
  STUB_PROD_ENVS=prod STUB_PERCENT=100 PROD_PERCENT=100 SAMPLE=10 run "$CHECK" sig-1-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"PASS prod at 100%, non-cohort user: true"* ]]
  [[ "$output" == *"FAIL production at 100%, non-cohort user: want true, got false"* ]]
  [[ "$output" == *"FAIL prod and production agree for 10 synthetic ids (10 differ)"* ]]
}

@test "check: a prod condition missing production (or prod) fails at 10% too" {
  stub_curl
  STUB_PROD_ENVS=prod STUB_PERCENT=10 PROD_PERCENT=10 SAMPLE=100 run "$CHECK" sig-1-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL prod and production agree for 100 synthetic ids (10 differ)"* ]]
  STUB_PROD_ENVS=production STUB_PERCENT=10 PROD_PERCENT=10 SAMPLE=100 run "$CHECK" sig-1-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL prod and production agree"* ]]
}

@test "check: a catch-all prod condition fails the fail-dark check at 100%" {
  stub_curl
  STUB_CATCH_ALL=1 STUB_PERCENT=100 PROD_PERCENT=100 SAMPLE=10 run "$CHECK" sig-1-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL fail dark, unknown environment"* ]]
}

@test "check: a catch-all prod condition is caught at 10% by the sample" {
  stub_curl
  STUB_CATCH_ALL=1 STUB_PERCENT=10 PROD_PERCENT=10 SAMPLE=100 run "$CHECK" sig-1-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL fail dark, 10/100 synthetic ids on with an unknown environment"* ]]
}

@test "check: refuses a sample too small to tell 10% from 0%" {
  stub_curl
  STUB_PERCENT=0 PROD_PERCENT=10 SAMPLE=20 run "$CHECK" sig-1-thing
  [ "$status" -ne 0 ]
  [[ "$output" == *"SAMPLE=20 is too small"* ]]
}

@test "check: missing flag is an error, not a silent false" {
  stub_curl
  STUB_MISSING=1 run "$CHECK" sig-1-thing
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in the /flags response"* ]]
}

@test "check: request failure is an error" {
  stub_curl
  STUB_FAIL=1 run "$CHECK" sig-1-thing
  [ "$status" -ne 0 ]
  [[ "$output" == *"/flags request failed"* ]]
}

@test "check: a failed request for a synthetic id in production stops the check, not counted as a mismatch" {
  stub_curl
  STUB_FAIL_ON="sig-flag-check-sig-1-thing-3 production" STUB_PERCENT=10 PROD_PERCENT=10 SAMPLE=100 run "$CHECK" sig-1-thing
  [ "$status" -ne 0 ]
  [[ "$output" == *"/flags request failed for distinct_id=sig-flag-check-sig-1-thing-3 environment=production"* ]]
  [[ "$output" != *"agree for"* ]]
}

@test "check: requires the token and both distinct ids" {
  run env -u POSTHOG_PROJECT_TOKEN QA_DISTINCT_ID=a OTHER_DISTINCT_ID=b "$CHECK" k
  [ "$status" -ne 0 ]
}
