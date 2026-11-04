#!/usr/bin/env bash
# staging-verdict.sh
#
# Records the staging test result for a promoted Release Candidate (SIG-2767,
# spec step 5 "Verify on staging", ADR 0001). Run after signapse-e2e on staging.
#
# Verdict: passed only when the suite job concluded `success` AND the suite
# reported `passed`. Anything else (tests failed, suite errored, run
# cancelled, job skipped) is a failure: an untested build never passes.
#
#   passed  every ticket gets STAGING_PASSED_LABEL, loses STAGING_FAILED_LABEL,
#           and gets a comment with the run and report links. The column is
#           not touched (tickets stay On Staging).
#   failed  every ticket gets STAGING_FAILED_LABEL, loses STAGING_PASSED_LABEL
#           and QA_PASSED_LABEL (QA approval does not survive QA Failed:
#           ADR 0001, spec "Board and labels"; otherwise a fix merged later
#           would ride on the old approval), gets the comment and moves to
#           QA_FAILED_STATE (Ticket Transitioner, never out of Done).
#           A Slack alert goes to SLACK_CHANNEL.
#
# Labels are added and removed one at a time (issueAddLabel/issueRemoveLabel),
# so the ticket's other labels stay. The label to add is resolved by name per
# ticket's team (team label first, then workspace label).
#
# Idempotent: a label already present is not re-added, an absent one is not
# removed, and the comment is skipped when the ticket already has one with the
# same run URL and verdict, so "Re-run failed jobs" gives the same end state.
#
# Every ticket is attempted; any Linear or Slack error fails the script at the
# end (exit 1), naming the tickets. Stdout: one JSON object
#   {verdict, staging_passed, reason, tickets, errors}
# printed even on failure, so the caller can still read the verdict.
#
# Env:
#   SUITE_JOB_RESULT   needs.<suite job>.result: success|failure|cancelled|skipped
#   SUITE_RESULT       the suite's `result` output: passed|failed|""
#   RUN_URL            this workflow run (required; the comment's idempotency key)
#   REPORT_URL         the suite's report_url (may be empty)
#   RC_TICKETS         comma-separated tickets (SIG-1,SIG-2); empty = none
#   REPOSITORY, RELEASE_TAG   shown in the comment and alert
#   STAGING_PASSED_LABEL (Staging Passed), STAGING_FAILED_LABEL (Staging Failed),
#   QA_FAILED_STATE (QA Failed), QA_PASSED_LABEL (QA Passed), LINEAR_TEAM_KEY
#   SLACK_CHANNEL, SLACK_BOT_TOKEN   required when the verdict is failed
#   LINEAR_API_KEY     required when there are tickets

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"
# shellcheck source=SCRIPTDIR/../lib/slack.sh
source "$(dirname "$0")/../lib/slack.sh"

need jq
need curl
: "${RUN_URL:?RUN_URL not set}"

PASSED_LABEL="${STAGING_PASSED_LABEL:-Staging Passed}"
FAILED_LABEL="${STAGING_FAILED_LABEL:-Staging Failed}"
QA_FAILED="${QA_FAILED_STATE:-QA Failed}"
QA_PASSED="${QA_PASSED_LABEL:-QA Passed}"
JOB="${SUITE_JOB_RESULT:-}"
SUITE="${SUITE_RESULT:-}"
REPORT="${REPORT_URL:-}"
WHAT="${REPOSITORY:-this repo}${RELEASE_TAG:+ \`$RELEASE_TAG\`}"

if [ "$JOB" = success ] && [ "$SUITE" = passed ]; then
  verdict=passed; add="$PASSED_LABEL"; drop=$(jq -nc --arg a "$FAILED_LABEL" '[$a]')
  reason="signapse-e2e passed on staging"
else
  verdict=failed; add="$FAILED_LABEL"; drop=$(jq -nc --arg a "$PASSED_LABEL" --arg b "$QA_PASSED" '[$a, $b]')
  case "$JOB" in
    success|failure)
      if [ "$SUITE" = failed ]; then reason="signapse-e2e failed on staging (tests failed or the suite could not run)"
      else reason="signapse-e2e returned no result (suite job $JOB), so the build is untested"; fi ;;
    cancelled) reason="the staging test run was cancelled, so the build is untested" ;;
    skipped)   reason="the staging test run was skipped, so the build is untested" ;;
    *)         reason="the staging test run did not report (job result '${JOB}'), so the build is untested" ;;
  esac
fi

tickets=$(jq -nc --arg t "${RC_TICKETS:-}" '$t | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))')
errors='[]'
add_error() { errors=$(jq -nc --argjson e "$errors" --arg m "$1" '$e + [$m]'); log "ERROR: $1"; }

report_line="Report: ${REPORT:-none (the suite produced no report)}"
if [ "$verdict" = passed ]; then
  comment="**${PASSED_LABEL}**: ${reason} for ${WHAT}. The ticket stays in its column and the pipeline continues to production."
else
  comment="**${FAILED_LABEL}**: ${reason} for ${WHAT}. Every ticket in the Release Candidate moves to **${QA_FAILED}**, because the pipeline cannot tell which ticket caused it. QA triages."
fi
comment="${comment}

Run: ${RUN_URL}
${report_line}"

# "team|name" -> label id, so each team's label is looked up once.
label_cache='{}'

# resolve_label <team-id> <name>: prints the label id. Team label first, then
# a workspace label (no team).
resolve_label() {
  local team="$1" name="$2" key id data
  key="$team|$name"
  id=$(jq -r --arg k "$key" '.[$k] // empty' <<< "$label_cache")
  if [ -z "$id" ]; then
    # shellcheck disable=SC2016 # GraphQL variable, not shell expansion.
    data=$(linear_gql 'query($n:String!){issueLabels(first:50,filter:{name:{eqIgnoreCase:$n}}){nodes{id name team{id}}}}' \
      "$(jq -nc --arg n "$name" '{n:$n}')") || return 1
    id=$(jq -r --arg t "$team" '.issueLabels.nodes as $n
      | (([$n[] | select(.team.id == $t)][0]) // ([$n[] | select(.team == null)][0]) // {}) | .id // empty' <<< "$data")
    [ -n "$id" ] || { echo "label '$name' does not exist for the ticket's team or workspace" >&2; return 1; }
    label_cache=$(jq -c --arg k "$key" --arg v "$id" '.[$k] = $v' <<< "$label_cache")
  fi
  printf '%s' "$id"
}

# mutate <field> <query> <vars>: runs a mutation and checks .<field>.success.
mutate() {
  local data
  data=$(linear_gql "$2" "$3") || return 1
  [ "$(jq -r --arg f "$1" '.[$f].success // false' <<< "$data")" = true ] || { echo "$1 did not succeed" >&2; return 1; }
}

# record_ticket <id>: labels and comment. Returns non-zero on any error. The
# caller runs it with set -e off, so every step checks its own status.
record_ticket() {
  local id="$1" data uuid team have add_id drop_ids lid
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  data=$(linear_gql 'query($id:String!,$run:String!){issue(id:$id){id identifier team{id} labels(first:250){nodes{id name}} comments(first:50,filter:{body:{contains:$run}}){nodes{body}}}}' \
    "$(jq -nc --arg id "$id" --arg run "$RUN_URL" '{id:$id, run:$run}')") || return 1
  uuid=$(jq -r '.issue.id // empty' <<< "$data")
  team=$(jq -r '.issue.team.id // empty' <<< "$data")
  [ -n "$uuid" ] && [ -n "$team" ] || { echo "issue lookup returned no id or team" >&2; return 1; }

  have=$(jq -r --arg n "$add" 'any(.issue.labels.nodes[]; (.name | ascii_downcase) == ($n | ascii_downcase))' <<< "$data")
  if [ "$have" != true ]; then
    add_id=$(resolve_label "$team" "$add") || return 1
    # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
    mutate issueAddLabel 'mutation($id:String!,$l:String!){issueAddLabel(id:$id,labelId:$l){success}}' \
      "$(jq -nc --arg id "$uuid" --arg l "$add_id" '{id:$id, l:$l}')" || return 1
    log "$id: added '$add'"
  fi

  drop_ids=$(jq -r --argjson n "$drop" '($n | map(ascii_downcase)) as $d
    | .issue.labels.nodes[] | select((.name | ascii_downcase) as $x | $d | index($x)) | "\(.id)\t\(.name)"' <<< "$data")
  while IFS=$'\t' read -r lid lname; do
    [ -n "$lid" ] || continue
    # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
    mutate issueRemoveLabel 'mutation($id:String!,$l:String!){issueRemoveLabel(id:$id,labelId:$l){success}}' \
      "$(jq -nc --arg id "$uuid" --arg l "$lid" '{id:$id, l:$l}')" || return 1
    log "$id: removed '$lname'"
  done <<< "$drop_ids"

  # Same run, same verdict: already commented (re-run). A re-run with another
  # verdict comments again, because the labels changed.
  if jq -e --arg v "**${add}**" 'any(.issue.comments.nodes[]; .body | contains($v))' <<< "$data" > /dev/null; then
    log "$id: already commented for this run"
  else
    # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
    mutate commentCreate 'mutation($id:String!,$b:String!){commentCreate(input:{issueId:$id,body:$b}){success}}' \
      "$(jq -nc --arg id "$uuid" --arg b "$comment" '{id:$id, b:$b}')" || return 1
    log "$id: commented"
  fi
}

errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
n=$(jq 'length' <<< "$tickets")
if [ "$n" -gt 0 ] && [ -z "${LINEAR_API_KEY:-}" ]; then
  add_error "LINEAR_API_KEY not set: no ticket was updated"
else
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    # Not in a subshell, so label_cache survives across tickets.
    set +e
    record_ticket "$t" 2> "$errf"
    rc=$?
    set -e
    cat "$errf" >&2
    [ "$rc" -eq 0 ] || add_error "$t: $(grep -v '^\[' "$errf" | tail -n 3 | tr '\n' ' ')"
  done < <(jq -r '.[]' <<< "$tickets")
fi

if [ "$verdict" = failed ]; then
  if [ "$n" -gt 0 ] && [ -n "${LINEAR_API_KEY:-}" ]; then
    set +e
    msg=$("$(dirname "$0")/promotion-tickets.sh" "$QA_FAILED" "${RC_TICKETS:-}" 2>&1 >/dev/null)
    rc=$?
    set -e
    [ -n "$msg" ] && printf '%s\n' "$msg" >&2
    [ "$rc" -eq 0 ] || add_error "move to '$QA_FAILED': $(tail -n 1 <<< "$msg")"
  fi

  if [ -z "${SLACK_CHANNEL:-}" ] || [ -z "${SLACK_BOT_TOKEN:-}" ]; then
    add_error "Slack alert not sent: slack_channel or SLACK_BOT_TOKEN is not set"
  else
    list=$(jq -r 'if length == 0 then "no tickets (untracked commits only)" else join(", ") end' <<< "$tickets")
    linear_note=""
    [ "$(jq length <<< "$errors")" -eq 0 ] || linear_note=$'\n'":warning: Some Linear updates failed; see the run."
    text=":x: *Staging tests failed for ${WHAT}*"$'\n'"Reason: ${reason}."$'\n'"${FAILED_LABEL} and moved to ${QA_FAILED}: ${list}"$'\n'"<${RUN_URL}|Run>${REPORT:+ · <${REPORT}|Report>}${linear_note}"
    set +e
    resp=$(jq -nc --arg c "$SLACK_CHANNEL" --arg t "$text" '{channel:$c, text:$t}' | slack_post 2>&1)
    set -e
    if [ "$(jq -r '.ok // false' <<< "$resp" 2>/dev/null)" = true ]; then
      log "Slack alert sent to $SLACK_CHANNEL"
    else
      add_error "Slack alert to $SLACK_CHANNEL failed: ${resp:0:200}"
    fi
  fi
fi

ok=$(jq 'length == 0' <<< "$errors")
jq -nc --arg v "$verdict" --arg r "$reason" --argjson t "$tickets" --argjson e "$errors" --argjson ok "$ok" \
  '{verdict:$v, staging_passed:($v == "passed" and $ok), reason:$r, tickets:$t, errors:$e}'
[ "$ok" = true ] || exit 1
