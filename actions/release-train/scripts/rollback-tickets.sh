#!/usr/bin/env bash
# rollback-tickets.sh
#
# After a failed prod smoke (SIG-2771, AC4, AC5): every ticket in the
# Deployment gets a comment with the run and moves to QA_FAILED_STATE (the
# pipeline cannot tell which ticket broke prod), losing QA Passed
# (qa-failed-tickets.sh: never out of Done; a Done ticket keeps QA Passed).
# Then a Slack alert goes to the repo's channel, naming which tickets are in
# QA Failed, which stayed where they were and which Linear could not move.
# When the rollback did not restore every service, the alert is critical
# (<!channel>) and names each service and why.
#
# Idempotent: a ticket that already has a comment with the marker and a
# "Run: <RUN_URL>" line equal to this run's is not commented again, and
# moving a ticket to the column it is in is a no-op. The Slack alert is posted again on a re-run (Slack has no
# idempotency key); its text says which attempt it is.
#
# Env:
#   RUN_URL (required), RUN_ATTEMPT, REPORT_URL, REPOSITORY, RELEASE_TAG
#   TICKETS             comma-separated (SIG-1,SIG-2); empty = none
#   QA_FAILED_STATE     default QA Failed
#   QA_PASSED_LABEL     default QA Passed: removed from every ticket in QA
#                       Failed (QA approval does not survive a rollback)
#   LINEAR_TEAM_KEY     team of the QA Failed column (default SIG)
#   ROLLBACK_OK         true | false
#   ROLLBACK_RESULTS    prod-rollback.sh's results array
#   CAUSE               what failed, default "Prod smoke failed"
#   INCIDENT_URL        the incident, when one was opened or found
#   NOTES               extra lines for the alert (failed Release or incident steps)
#   LINEAR_API_KEY      required when there are tickets
#   SLACK_CHANNEL, SLACK_BOT_TOKEN   required
# Stdout: {ok, tickets, critical, errors}. Exit 1 when anything failed.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"
# shellcheck source=SCRIPTDIR/../lib/slack.sh
source "$(dirname "$0")/../lib/slack.sh"

need jq
need curl
: "${RUN_URL:?RUN_URL not set}"

QA_FAILED="${QA_FAILED_STATE:-QA Failed}"
WHAT="${REPOSITORY:-this repo}${RELEASE_TAG:+ \`$RELEASE_TAG\`}"
RESULTS="${ROLLBACK_RESULTS:-}"
[ -n "$RESULTS" ] || RESULTS='[]'
jq -e 'type == "array"' <<< "$RESULTS" > /dev/null 2>&1 || RESULTS='[]'
critical=true
[ "${ROLLBACK_OK:-false}" = true ] && critical=false
MARKER="**Prod smoke failed**"

tickets=$(jq -nc --arg t "${TICKETS:-}" '$t | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))')
n=$(jq length <<< "$tickets")
errors='[]'
add_error() { errors=$(jq -nc --argjson e "$errors" --arg m "$1" '$e + [$m]'); log "ERROR: $1"; }

if [ "$critical" = false ]; then
  outcome="Prod was rolled back automatically to the previous version: $(jq -r 'map("`\(.service)` → `\(.restored)`") | join(", ")' <<< "$RESULTS")."
else
  outcome="The automatic rollback did NOT restore every service, so prod may still run this build: $(jq -r 'map("`\(.service)`: \(.reason)") | join("; ")' <<< "$RESULTS")."
fi
comment="${MARKER} after ${WHAT} was deployed. ${outcome} Every ticket in the Deployment moves to **${QA_FAILED}**, because the pipeline cannot tell which ticket caused it. QA triages.

Run: ${RUN_URL}
Report: ${REPORT_URL:-none}${INCIDENT_URL:+
Incident: ${INCIDENT_URL}}"

comment_ticket() { # comment_ticket <id>
  local id="$1" data uuid
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  data=$(linear_gql 'query($id:String!,$run:String!){issue(id:$id){id comments(first:50,filter:{body:{contains:$run}}){nodes{body}}}}' \
    "$(jq -nc --arg id "$id" --arg run "$RUN_URL" '{id:$id, run:$run}')") || return 1
  uuid=$(jq -r '.issue.id // empty' <<< "$data")
  [ -n "$uuid" ] || { echo "issue lookup returned no id" >&2; return 1; }
  if jq -e --arg m "$MARKER" --arg r "Run: ${RUN_URL}" \
    'any(.issue.comments.nodes[]; (.body | contains($m)) and (.body | split("\n") | index($r)))' <<< "$data" > /dev/null; then
    log "$id: already commented for this run"
    return 0
  fi
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  data=$(linear_gql 'mutation($id:String!,$b:String!){commentCreate(input:{issueId:$id,body:$b}){success}}' \
    "$(jq -nc --arg id "$uuid" --arg b "$comment" '{id:$id, b:$b}')") || return 1
  [ "$(jq -r '.commentCreate.success // false' <<< "$data")" = true ] || { echo "commentCreate did not succeed" >&2; return 1; }
  log "$id: commented"
}

errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
moves=$(jq -c '{moved: [], already: [], kept: [], failed: .}' <<< "$tickets")
if [ "$n" -gt 0 ]; then
  if [ -z "${LINEAR_API_KEY:-}" ]; then
    add_error "LINEAR_API_KEY not set: no ticket was updated"
  else
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      set +e
      comment_ticket "$t" 2> "$errf"
      rc=$?
      set -e
      cat "$errf" >&2
      [ "$rc" -eq 0 ] || add_error "$t: comment: $(grep -v '^\[' "$errf" | tail -n 2 | tr '\n' ' ')"
    done < <(jq -r '.[]' <<< "$tickets")
    # QA Passed goes with the move (ADR 0001, spec "Board and labels"): a fix
    # merged later must not be selectable on the old approval.
    set +e
    out=$(QA_FAILED_STATE="$QA_FAILED" "$(dirname "$0")/qa-failed-tickets.sh" "${TICKETS:-}" 2> "$errf")
    rc=$?
    set -e
    cat "$errf" >&2
    jq -e 'type == "object"' <<< "$out" > /dev/null 2>&1 && moves="$out"
    [ "$rc" -eq 0 ] || add_error "QA Failed: $(jq -r '(.errors // []) | join("; ")' <<< "$moves" 2> /dev/null || tail -n 1 "$errf")"
  fi
fi

if [ -z "${SLACK_CHANNEL:-}" ] || [ -z "${SLACK_BOT_TOKEN:-}" ]; then
  add_error "Slack alert not sent: slack_channel or SLACK_BOT_TOKEN is not set"
else
  # Say what happened to each ticket, not what was meant to.
  # shellcheck disable=SC2016 # jq program, not shell expansion.
  moved_text=$(jq -r --argjson t "$tickets" --arg qf "$QA_FAILED" '
    if ($t | length) == 0 then "No tickets (untracked commits only)."
    else [ (if (.moved + .already | length) > 0 then "In \($qf): \(.moved + .already | join(", "))" else empty end),
           (if (.kept | length) > 0 then "Left where they are: \(.kept | map("\(.id) (\(.state))") | join(", "))" else empty end),
           (if (.failed | length) > 0 then ":warning: NOT moved to \($qf) (Linear failed): \(.failed | join(", "))" else empty end)
         ] | join("\n") end' <<< "$moves")
  attempt=""
  [ "${RUN_ATTEMPT:-1}" = 1 ] || attempt=" (re-run, attempt ${RUN_ATTEMPT})"
  if [ "$critical" = true ]; then
    head=":rotating_light: <!channel> *Prod rollback FAILED for ${WHAT}*${attempt}"
  else
    head=":rewind: *${CAUSE:-Prod smoke failed} for ${WHAT}; rolled back*${attempt}"
  fi
  linear_note=""
  [ "$(jq length <<< "$errors")" -eq 0 ] || linear_note=$'\n'":warning: Some Linear updates failed; see the run."
  text="${head}"$'\n'"${outcome}"$'\n'"${moved_text}"$'\n'"<${RUN_URL}|Run>${REPORT_URL:+ · <${REPORT_URL}|Report>}${INCIDENT_URL:+ · <${INCIDENT_URL}|Incident>}${NOTES:+$'\n'${NOTES}}${linear_note}"
  set +e
  resp=$(jq -nc --arg c "$SLACK_CHANNEL" --arg t "$text" '{channel:$c, text:$t}' | slack_post 2>&1)
  set -e
  if [ "$(jq -r '.ok // false' <<< "$resp" 2> /dev/null)" = true ]; then
    log "Slack alert sent to $SLACK_CHANNEL"
  else
    add_error "Slack alert to $SLACK_CHANNEL failed: ${resp:0:200}"
  fi
fi

ok=$(jq 'length == 0' <<< "$errors")
jq -nc --argjson t "$tickets" --argjson e "$errors" --argjson ok "$ok" --argjson c "$critical" \
  '{ok: $ok, tickets: $t, critical: $c, errors: $e}'
[ "$ok" = true ] || exit 1
