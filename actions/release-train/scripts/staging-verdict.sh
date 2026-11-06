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
#           not touched (tickets stay On Staging). A ticket already in
#           QA_FAILED_STATE (an earlier attempt failed, e.g. a re-run that
#           flips the verdict) keeps staging_passed false: only QA takes it
#           out of QA Failed.
#   failed  every ticket gets STAGING_FAILED_LABEL, loses STAGING_PASSED_LABEL,
#           gets the comment and moves to QA_FAILED_STATE, losing
#           QA_PASSED_LABEL (qa-failed-tickets.sh: QA approval does not
#           survive QA Failed, ADR 0001; a Done ticket is never moved and
#           keeps it). A Slack alert goes to SLACK_CHANNEL and says which
#           tickets actually moved.
#
# Labels are added and removed one at a time (issueAddLabel/issueRemoveLabel),
# so the ticket's other labels stay. The label to add is resolved by name per
# ticket's team (team label first, then workspace label).
#
# Idempotent: a label already present is not re-added, an absent one is not
# removed, and the comment is skipped when the ticket already has one with the
# verdict and a "Run: <RUN_URL>" line equal to this run's (not a prefix: run
# 42 is not run 421), so "Re-run failed jobs" gives the same end state.
#
# Every ticket is attempted; any Linear or Slack error fails the script at the
# end (exit 1), naming the tickets. Stdout: one JSON object
#   {verdict, staging_passed, reason, tickets, errors, moves}
# moves is qa-failed-tickets.sh's {moved, already, kept, failed} on a failure,
# null on a pass.
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
#   (defaults match release-train.yml's; the workflow does not override them)
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
  verdict=passed; add="$PASSED_LABEL"; drop="$FAILED_LABEL"
  reason="signapse-e2e passed on staging"
else
  verdict=failed; add="$FAILED_LABEL"; drop="$PASSED_LABEL"
  case "$JOB" in
    success|failure)
      if [ "$SUITE" = failed ]; then reason="signapse-e2e failed on staging (tests failed or the suite could not run)"
      else reason="signapse-e2e returned no result (suite job $JOB), so the build is untested"; fi ;;
    cancelled) reason="the staging test run was cancelled, so the build is untested" ;;
    skipped)   reason="the staging test run was skipped, so the build is untested" ;;
    *)         reason="the staging test run did not report (job result '${JOB}'), so the build is untested" ;;
  esac
fi

tickets=$(csv_json "${RC_TICKETS:-}")
errors='[]'
add_error() { errors=$(jq -nc --argjson e "$errors" --arg m "$1" '$e + [$m]'); log "ERROR: $1"; }

report_line="Report: ${REPORT:-none (the suite produced no report)}"
if [ "$verdict" = passed ]; then
  comment="**${PASSED_LABEL}**: ${reason} for ${WHAT}. The ticket stays in its column and the pipeline continues to production."
  # A ticket an earlier attempt sent to QA Failed gets this one instead.
  comment_qa_failed="**${PASSED_LABEL}**: ${reason} for ${WHAT}. An earlier attempt sent this ticket to **${QA_FAILED}**, so production waits until QA re-passes it."
else
  comment="**${FAILED_LABEL}**: ${reason} for ${WHAT}. Tickets in the Release Candidate that are not Done move to **${QA_FAILED}**, because the pipeline cannot tell which ticket caused it. QA triages."
fi
footer="

Run: ${RUN_URL}
${report_line}"
in_qa_failed='[]'   # passed verdict: tickets already in QA Failed

# "team|name" -> label id, so each team's label is looked up once.
label_cache='{}'

# resolve_label <team-id> <name>: sets LABEL_ID. Team label first, then a
# workspace label (no team). Sets a global rather than printing, because
# $(...) would run it in a subshell and drop the cache update.
LABEL_ID=''
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
  LABEL_ID="$id"
}

# mutate <field> <query> <vars>: runs a mutation and checks .<field>.success.
mutate() {
  local data
  data=$(linear_gql "$2" "$3") || return 1
  [ "$(jq -r --arg f "$1" '.[$f].success // false' <<< "$data")" = true ] || { echo "$1 did not succeed" >&2; return 1; }
}

# record_ticket <id>: adds the label and comments. Returns non-zero on any
# error. The caller runs it with set -e off, so every step checks its own status.
record_ticket() {
  local id="$1" data uuid team have add_id body="$comment"
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  data=$(linear_gql 'query($id:String!,$run:String!){issue(id:$id){id identifier team{id} state{name} labels(first:250){nodes{id name}} comments(first:50,filter:{body:{contains:$run}}){nodes{body}}}}' \
    "$(jq -nc --arg id "$id" --arg run "$RUN_URL" '{id:$id, run:$run}')") || return 1
  uuid=$(jq -r '.issue.id // empty' <<< "$data")
  team=$(jq -r '.issue.team.id // empty' <<< "$data")
  [ -n "$uuid" ] && [ -n "$team" ] || { echo "issue lookup returned no id or team" >&2; return 1; }

  have=$(jq -r --arg n "$add" 'any(.issue.labels.nodes[]; (.name | ascii_downcase) == ($n | ascii_downcase))' <<< "$data")
  if [ "$have" != true ]; then
    resolve_label "$team" "$add" || return 1
    add_id="$LABEL_ID"
    # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
    mutate issueAddLabel 'mutation($id:String!,$l:String!){issueAddLabel(id:$id,labelId:$l){success}}' \
      "$(jq -nc --arg id "$uuid" --arg l "$add_id" '{id:$id, l:$l}')" || return 1
    log "$id: added '$add'"
  fi

  if [ "$verdict" = passed ] && [ "$(jq -r '.issue.state.name // ""' <<< "$data")" = "$QA_FAILED" ]; then
    in_qa_failed=$(jq -c --arg id "$id" '. + [$id]' <<< "$in_qa_failed")
    body="$comment_qa_failed"
  fi

  # Same run, same verdict: already commented (re-run). A re-run with another
  # verdict comments again, because the labels changed.
  if jq -e --arg v "**${add}**" --arg r "Run: ${RUN_URL}" \
    'any(.issue.comments.nodes[]; (.body | contains($v)) and (.body | split("\n") | index($r)))' <<< "$data" > /dev/null; then
    log "$id: already commented for this run"
  else
    # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
    mutate commentCreate 'mutation($id:String!,$b:String!){commentCreate(input:{issueId:$id,body:$b}){success}}' \
      "$(jq -nc --arg id "$uuid" --arg b "${body}${footer}" '{id:$id, b:$b}')" || return 1
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
  "$(dirname "$0")/ticket-labels-remove.sh" "$drop" "${RC_TICKETS:-}" > /dev/null 2> "$errf" \
    || add_error "removing '$drop': $(tail -n 1 "$errf")"
  cat "$errf" >&2
fi
if [ "$in_qa_failed" != '[]' ]; then
  reason="${reason}, but production waits: an earlier attempt left $(jq -r 'join(", ")' <<< "$in_qa_failed") in ${QA_FAILED}"
fi

moves=null

if [ "$verdict" = failed ]; then
  moves='{"moved":[],"already":[],"kept":[],"failed":[]}'
  if [ "$n" -gt 0 ] && [ -n "${LINEAR_API_KEY:-}" ]; then
    set +e
    out=$(QA_PASSED_LABEL="$QA_PASSED" "$(dirname "$0")/qa-failed-tickets.sh" "${RC_TICKETS:-}" 2> "$errf")
    rc=$?
    set -e
    cat "$errf" >&2
    jq -e 'type == "object"' <<< "$out" > /dev/null 2>&1 && moves="$out"
    [ "$rc" -eq 0 ] || add_error "QA Failed: $(jq -r '(.errors // []) | join("; ")' <<< "$moves" 2> /dev/null || tail -n 1 "$errf")"
  elif [ "$n" -gt 0 ]; then
    moves=$(jq -c '{moved: [], already: [], kept: [], failed: .}' <<< "$tickets")
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
    linear_note=""
    [ "$(jq length <<< "$errors")" -eq 0 ] || linear_note=$'\n'":warning: Some Linear updates failed; see the run."
    text=":x: *Staging tests failed for ${WHAT}*"$'\n'"Reason: ${reason}."$'\n'"${moved_text}"$'\n'"<${RUN_URL}|Run>${REPORT:+ · <${REPORT}|Report>}${linear_note}"
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
# shellcheck disable=SC2016 # jq bindings, not shell expansion.
jq -nc --arg v "$verdict" --arg r "$reason" --argjson t "$tickets" --argjson e "$errors" --argjson ok "$ok" \
  --argjson q "$in_qa_failed" --argjson m "$moves" \
  '{verdict:$v, staging_passed:($v == "passed" and $ok and $q == []), reason:$r, tickets:$t, errors:$e, moves:$m}'
[ "$ok" = true ] || exit 1
