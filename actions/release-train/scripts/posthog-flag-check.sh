#!/usr/bin/env bash
# posthog-flag-check.sh <flag-key>
#
# Read-only check that a flag built from the standard setup
# (docs/POSTHOG-FLAGS.md) answers as it should, through PostHog's public
# /flags evaluation endpoint. It writes nothing to PostHog and creates no
# persons: /flags only evaluates.
#
#   dev, development, staging  -> on for the QA user and the other user
#   prod                       -> on for the QA user
#   prod, production           -> other user off at 0, on at 100
#   SAMPLE synthetic ids       -> on for about PROD_PERCENT% of them, half
#                                 evaluated as prod and half as production
#                                 (exactly none at 0, exactly all at 100)
#   empty/unknown environment   -> off for the other user; unknown -> off for every
#                                 synthetic id, at any percentage
#
# Env:
#   POSTHOG_PROJECT_TOKEN  required, the public token (phc_...) of the PROD project
#                          (256388 SignStream Production). Every flag check reads
#                          the prod project; the dev project (275880) has the
#                          same flag on for everyone and nothing to check.
#   QA_DISTINCT_ID         required, distinct_id of a QA Cohort member
#   OTHER_DISTINCT_ID      required, distinct_id of a user (PostHog person) outside the cohort
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
  resp=$(curl -sS --fail --connect-timeout 5 --max-time 20 -X POST "${HOST%/}/flags?v=2" \
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
  expect true "$QA_DISTINCT_ID" "$env" "AC2 $env, QA Cohort user"
  expect true "$OTHER_DISTINCT_ID" "$env" "AC2 $env, non-cohort user"
done
expect true "$QA_DISTINCT_ID" prod "AC3 prod, QA Cohort user"
for env in prod production; do
  if [ "$PERCENT" -eq 0 ]; then
    expect false "$OTHER_DISTINCT_ID" "$env" "AC2 $env at 0%, non-cohort user"
  elif [ "$PERCENT" -eq 100 ]; then
    expect true "$OTHER_DISTINCT_ID" "$env" "$env at 100%, non-cohort user"
  fi
done
expect false "$OTHER_DISTINCT_ID" "" "fail dark, empty environment, non-cohort user"
expect false "$OTHER_DISTINCT_ID" unknown "fail dark, unknown environment, non-cohort user"

# Accept within 3 standard deviations of the binomial mean.
read -r lo hi < <(awk -v n="$N" -v p="$PERCENT" 'BEGIN {
  p /= 100; m = n * p; s = 3 * sqrt(n * p * (1 - p))
  lo = int(m - s); if (lo < 0) lo = 0
  hi = int(m + s + 0.999999); if (hi > n) hi = n
  printf "%d\t%d\n", lo, hi }')
# Between 0 and 100 the band must exclude "none on" and "all on", or a flag
# stuck at 0% (or 100%) would pass.
if [ "$PERCENT" -gt 0 ] && [ "$PERCENT" -lt 100 ] && { [ "$lo" -eq 0 ] || [ "$hi" -ge "$N" ]; }; then
  die "SAMPLE=$N is too small to tell ${PERCENT}% from 0% or 100%; raise SAMPLE"
fi

# AC4: share of synthetic non-cohort ids that get the flag in prod. Odd ids
# send the legacy `production`, which today's apps still send.
# The same ids with an unknown environment must all stay off, whatever the
# percentage, so a catch-all prod condition cannot hide behind one user.
on=0
leaked=0
for i in $(seq 1 "$N"); do
  env=prod
  [ $((i % 2)) -eq 0 ] || env=production
  r=$(evaluate "sig-flag-check-${KEY}-${i}" "$env")
  if [ "$r" = true ]; then on=$((on + 1)); fi
  r=$(evaluate "sig-flag-check-${KEY}-${i}" unknown)
  if [ "$r" = true ]; then leaked=$((leaked + 1)); fi
done
label="fail dark, ${leaked}/${N} synthetic ids on with an unknown environment"
if [ "$leaked" -eq 0 ]; then pass "$label"; else fail "$label"; fi
label="AC4 prod at ${PERCENT}%, ${on}/${N} synthetic non-cohort ids on (accept ${lo}-${hi})"
if [ "$on" -ge "$lo" ] && [ "$on" -le "$hi" ]; then pass "$label"; else fail "$label"; fi

[ "$failures" -eq 0 ] || { log "$failures check(s) failed for $KEY"; exit 1; }
log "all checks passed for $KEY"
