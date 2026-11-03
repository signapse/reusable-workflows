#!/usr/bin/env bash
# posthog-flag-check.sh <flag-key>
#
# Read-only check that a flag built from the standard setup
# (docs/POSTHOG-FLAGS.md) answers as it should, through PostHog's public
# /flags evaluation endpoint. It writes nothing to PostHog and creates no
# persons: /flags only evaluates.
#
#   dev, development, staging  -> on for the QA account and the other account
#   prod                       -> on for the QA account
#   prod, SAMPLE synthetic ids -> on for about PROD_PERCENT% of them
#                                 (exactly none at 0, exactly all at 100)
#
# Env:
#   POSTHOG_PROJECT_TOKEN  required, the public project token (phc_...)
#   QA_DISTINCT_ID         required, distinct_id of a QA Cohort member
#   OTHER_DISTINCT_ID      required, distinct_id of an account outside the cohort
#   PROD_PERCENT           the prod Rollout percentage the flag is set to (default 0)
#   SAMPLE                 synthetic ids to evaluate in prod (default 100)
#   POSTHOG_HOST           default https://eu.i.posthog.com
#
# Exits 1 if any check fails.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -ge 1 ] || die "usage: posthog-flag-check.sh <flag-key>"
KEY="$1"

need curl
need jq
need awk

: "${POSTHOG_PROJECT_TOKEN:?POSTHOG_PROJECT_TOKEN is required}"
: "${QA_DISTINCT_ID:?QA_DISTINCT_ID is required}"
: "${OTHER_DISTINCT_ID:?OTHER_DISTINCT_ID is required}"
HOST="${POSTHOG_HOST:-https://eu.i.posthog.com}"
PERCENT="${PROD_PERCENT:-0}"
N="${SAMPLE:-100}"
[[ "$PERCENT" =~ ^[0-9]+$ ]] && [ "$PERCENT" -le 100 ] || die "PROD_PERCENT must be 0-100 (got '$PERCENT')"
[[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -gt 0 ] || die "SAMPLE must be a positive integer (got '$N')"

failures=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }

# evaluate <distinct_id> <environment> -> prints true|false
evaluate() {
  local body resp
  body=$(jq -nc --arg t "$POSTHOG_PROJECT_TOKEN" --arg d "$1" --arg e "$2" \
    '{api_key: $t, distinct_id: $d, person_properties: {environment: $e}}')
  resp=$(curl -sS --fail -X POST "${HOST%/}/flags?v=2" \
    -H 'Content-Type: application/json' --data-binary "$body") \
    || die "/flags request failed for distinct_id=$1 environment=$2"
  jq -er --arg k "$KEY" '.flags[$k].enabled | if type == "boolean" then tostring else error("missing") end' <<< "$resp" 2> /dev/null \
    || die "flag '$KEY' not in the /flags response (wrong key, inactive, or other project)"
}

expect() { # expect <want> <distinct_id> <environment> <label>
  local got
  got=$(evaluate "$2" "$3")
  if [ "$got" = "$1" ]; then pass "$4: $got"; else fail "$4: want $1, got $got"; fi
}

for env in dev development staging; do
  expect true "$QA_DISTINCT_ID" "$env" "AC2 $env, QA Cohort account"
  expect true "$OTHER_DISTINCT_ID" "$env" "AC2 $env, non-cohort account"
done
expect true "$QA_DISTINCT_ID" prod "AC3 prod, QA Cohort account"
expect true "$QA_DISTINCT_ID" production "AC3 production (legacy value), QA Cohort account"
if [ "$PERCENT" -eq 0 ]; then
  expect false "$OTHER_DISTINCT_ID" prod "AC2 prod at 0%, non-cohort account"
elif [ "$PERCENT" -eq 100 ]; then
  expect true "$OTHER_DISTINCT_ID" prod "prod at 100%, non-cohort account"
fi

# AC4: share of synthetic non-cohort ids that get the flag in prod.
on=0
for i in $(seq 1 "$N"); do
  r=$(evaluate "sig-flag-check-${KEY}-${i}" prod)
  if [ "$r" = true ]; then on=$((on + 1)); fi
done
# Accept within 3 standard deviations of the binomial mean.
read -r lo hi < <(awk -v n="$N" -v p="$PERCENT" 'BEGIN {
  p /= 100; m = n * p; s = 3 * sqrt(n * p * (1 - p))
  lo = int(m - s); if (lo < 0) lo = 0
  hi = int(m + s + 0.999999); if (hi > n) hi = n
  printf "%d\t%d\n", lo, hi }')
label="AC4 prod at ${PERCENT}%, ${on}/${N} synthetic non-cohort ids on (accept ${lo}-${hi})"
if [ "$on" -ge "$lo" ] && [ "$on" -le "$hi" ]; then pass "$label"; else fail "$label"; fi

[ "$failures" -eq 0 ] || { log "$failures check(s) failed for $KEY"; exit 1; }
log "all checks passed for $KEY"
