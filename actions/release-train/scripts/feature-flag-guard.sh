#!/usr/bin/env bash
# feature-flag-guard.sh
#
# AC5 of SIG-2769 (ADR 0004): a Dark Deployment keeps every Feature ticket's
# flag on for the QA Cohort only in prod. This only reads PostHog; it never
# changes a flag. For each Feature ticket that has not started a Rollout, it
# finds the ticket's flags (key prefix sig-<n>-, docs/POSTHOG-FLAGS.md
# "Naming") and fails if any condition other than these has a rollout
# percentage above 0:
#   - the QA Cohort condition: every property is the cohort QA_COHORT_ID
#     (review fix: any other cohort, e.g. one holding every user, is not the
#     QA Cohort and fails)
#   - the dev/staging condition (an `environment` property whose values are
#     all dev, development or staging)
# That covers the template's prod condition (groups[2]) and any hand-added
# catch-all. PostHog treats a null rollout_percentage as 100.
# A Feature ticket with no flag fails too: ADR 0004 says it must ship behind one.
#
# Stdin: prod-tickets.sh output, [{id, found, state, labels}].
# Env:
#   POSTHOG_API_KEY     personal API key with feature_flag:read only (required
#                       when there is a Feature ticket to check)
#   QA_COHORT_ID        PostHog id of the QA Cohort in the prod project (required
#                       when there is a Feature ticket to check; SIG-2749 creates it)
#   POSTHOG_PROJECT_ID  the PROD project, default 256388 (workflow input
#                       posthog_project_id_prod). Flags also exist in the dev
#                       project 275880, on for everyone; the guard never reads
#                       it (Decision (Alex, 2026-11-09) 10).
#   POSTHOG_HOST        default https://eu.posthog.com
#   FEATURE_LABEL       default Feature
#   ROLLOUT_STATES      comma-separated columns where a Rollout has started
#                       and the guard no longer applies (default "Rolling Out,Done")
# Stdout: {ok, checked: [{ticket, flag, active, offending: [{index, rollout_percentage}]}],
#          skipped: [{ticket, reason}], errors: [..]}
# Exits 1 when ok is false (after printing).

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need jq
need curl

FEATURE_LABEL="${FEATURE_LABEL:-Feature}"
ROLLOUT_STATES="${ROLLOUT_STATES:-Rolling Out,Done}"
POSTHOG_PROJECT_ID="${POSTHOG_PROJECT_ID:-256388}"
POSTHOG_HOST="${POSTHOG_HOST:-https://eu.posthog.com}"
[[ "$POSTHOG_PROJECT_ID" =~ ^[0-9]+$ ]] || die "POSTHOG_PROJECT_ID must be numeric (got '$POSTHOG_PROJECT_ID')"

tickets=$(jq -c 'if type == "array" then . else error("not an array") end' 2> /dev/null) \
  || die "stdin must be prod-tickets.sh output (a JSON array)"
# shellcheck disable=SC2016 # jq bindings, not shell expansion.
split=$(jq -c --arg f "$FEATURE_LABEL" --arg rs "$ROLLOUT_STATES" '
  ($rs | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $started
  | [.[] | select(.found and (.labels | index($f)))]
  | {check: [.[] | select(.state as $s | $started | index($s) | not) | .id],
     skipped: [.[] | select(.state as $s | $started | index($s)) | {ticket: .id, reason: "Rollout started (\(.state))"}]}' <<< "$tickets")

checked='[]'
errors='[]'
err() { errors=$(jq -c --arg e "$1" '. + [$e]' <<< "$errors"); }

ids=$(jq -r '.check[]' <<< "$split")
QA_COHORT_ID="${QA_COHORT_ID:-}"
if [ -n "$ids" ] && [ -z "${POSTHOG_API_KEY:-}" ]; then
  err "POSTHOG_API_KEY is not set, so the Feature flags of $(jq -r '.check | join(", ")' <<< "$split") cannot be checked"
  ids=""
elif [ -n "$ids" ] && ! [[ "$QA_COHORT_ID" =~ ^[0-9]+$ ]]; then
  err "qa_cohort_id (QA_COHORT_ID) is not set to a PostHog cohort id, so the Feature flags of $(jq -r '.check | join(", ")' <<< "$split") cannot be checked against the QA Cohort"
  ids=""
fi

while IFS= read -r id; do
  [ -n "$id" ] || continue
  [[ "$id" =~ -([0-9]+)$ ]] || { err "$id: not a ticket id"; continue; }
  prefix="sig-${BASH_REMATCH[1]}-"
  # Every page of the search: a leaking flag on page 2 must not pass.
  url="${POSTHOG_HOST%/}/api/projects/${POSTHOG_PROJECT_ID}/feature_flags/?search=${prefix}&limit=100"
  resp='{"results":[]}'
  pages=0
  while [ -n "$url" ]; do
    pages=$((pages + 1))
    if [ "$pages" -gt 20 ] || ! page=$(curl -sS --fail --connect-timeout 5 --max-time 30 \
      -H "Authorization: Bearer ${POSTHOG_API_KEY}" "$url") \
      || ! jq -e '(.results | type) == "array"' <<< "$page" > /dev/null 2>&1; then
      resp=""
      break
    fi
    resp=$(jq -c --argjson p "$page" '.results += $p.results' <<< "$resp")
    url=$(jq -r '.next // empty' <<< "$page")
  done
  if [ -z "$resp" ]; then
    err "$id: PostHog flag lookup failed"
    continue
  fi
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  if ! flags=$(jq -c --arg p "$prefix" --arg t "$id" --arg qc "$QA_COHORT_ID" '
    [.results[] | select((.key | startswith($p)) and (.deleted | not))
     | {ticket: $t, flag: .key, active: (.active // false),
        offending: [.filters.groups // [] | to_entries[]
          | .value as $g
          | ($g.properties // []) as $props
          | select(
              (($props | length) > 0 and ($props | all(.type == "cohort" and ((.value | tostring) == $qc)))) as $cohort_only
              | ($props | any(.key == "environment" and .type == "person"
                  and ((.value | if type == "array" then . else [.] end) as $v
                       | ($v | length) > 0
                       and ($v | all(. == "dev" or . == "development" or . == "staging"))))) as $preprod
              | ($cohort_only or $preprod) | not)
          | {index: .key, rollout_percentage: ($g.rollout_percentage // 100)}
          | select(.rollout_percentage > 0)]}]' <<< "$resp" 2> /dev/null); then
    err "$id: unexpected PostHog answer"
    continue
  fi
  if [ "$(jq length <<< "$flags")" -eq 0 ]; then
    err "$id is a Feature ticket but has no PostHog flag ${prefix}* (ADR 0004: Feature tickets ship behind a flag)"
    continue
  fi
  checked=$(jq -c --argjson f "$flags" '. + $f' <<< "$checked")
done <<< "$ids"

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
jq -nc --argjson c "$checked" --argjson s "$(jq -c .skipped <<< "$split")" --argjson e "$errors" '
  ($e + [$c[] | select(.offending | length > 0)
         | "\(.ticket): flag \(.flag) is on in prod beyond the QA Cohort before any Rollout ("
           + ([.offending[] | "condition \(.index) at \(.rollout_percentage)%"] | join(", ")) + ")"]) as $all
  | {ok: ($all | length == 0), checked: $c, skipped: $s, errors: $all}'
[ "$(jq -n --argjson c "$checked" --argjson e "$errors" '($e | length) == 0 and all($c[]; .offending | length == 0)')" = true ]
