#!/usr/bin/env bash
# ticket-transitioner.sh <target-state-name>
#
# Reads ["SIG-1","SIG-2"] on stdin. Moves each ticket to the given column of
# the Linear team LINEAR_TEAM_KEY (default SIG). Emits
# [{id, success, moved, from?, reason?, error?}, ...] on stdout.
#
# Moves only forward (review fix, SIG-2764):
#   * a ticket already in the target column is left alone (moved: false);
#   * a ticket in QA_FAILED_STATE (default "QA Failed") or DONE_STATE
#     (default "Done") is never moved out: ADR 0001, only QA takes a ticket
#     out of QA Failed, and Done is final;
#   * ALLOWED_FROM (comma-separated column names), when set, lists the only
#     columns a ticket may be moved from. Any other column is skipped, so a
#     ticket that is already further on (On Prod, Rolling Out) is never moved
#     back to On Staging by a follow-up commit.
# A skipped ticket is success: true, moved: false with a reason. Only Linear
# errors are success: false.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

[ $# -eq 1 ] || die "usage: ticket-transitioner.sh <state-name>"
STATE_NAME="$1"
need jq
TEAM_KEY="${LINEAR_TEAM_KEY:-SIG}"
QA_FAILED="${QA_FAILED_STATE:-QA Failed}"
DONE="${DONE_STATE:-Done}"
allowed=$(jq -nc --arg a "${ALLOWED_FROM:-}" '$a | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))')

tickets=$(jq -r '.[]?')

# Empty input is not a failure (Task 3 regression class): short-circuit
# before requiring LINEAR_API_KEY so callers with nothing to do don't need
# credentials configured.
if [ -z "$tickets" ]; then
  echo '[]'
  exit 0
fi

if [ -z "${LINEAR_API_KEY:-}" ]; then
  die "LINEAR_API_KEY not set"
fi

# Resolve the state ID once, on the configured team.
# shellcheck disable=SC2016 # GraphQL variables ($name), not shell expansion.
STATE_ID=$(linear_query 'query($name:String!,$team:String!){workflowStates(filter:{name:{eq:$name},team:{key:{eq:$team}}}){nodes{id}}}' \
  "$(jq -nc --arg n "$STATE_NAME" --arg t "$TEAM_KEY" '{name:$n, team:$t}')" \
  | jq -r '.data.workflowStates.nodes[0].id // empty')
[ -n "$STATE_ID" ] || die "state '$STATE_NAME' not found on team $TEAM_KEY"

results='[]'
add() { results=$(jq -c --argjson e "$1" '. + [$e]' <<< "$results"); }
while IFS= read -r id; do
  # shellcheck disable=SC2016 # GraphQL variables ($id), not shell expansion.
  cur=$(linear_query 'query($id:String!){issue(id:$id){state{name}}}' "$(jq -nc --arg id "$id" '{id:$id}')" \
    | jq -r '.data.issue.state.name // empty' 2> /dev/null || true)
  if [ -z "$cur" ]; then
    add "$(jq -nc --arg id "$id" '{id:$id, success:false, moved:false, error:"cannot read the ticket'"'"'s column"}')"
    continue
  fi
  reason=""
  if [ "$cur" = "$STATE_NAME" ]; then
    reason="already in ${STATE_NAME}"
  elif [ "$cur" = "$QA_FAILED" ] || [ "$cur" = "$DONE" ]; then
    reason="in ${cur}; never moved out of it by the pipeline"
  elif [ "$allowed" != '[]' ] && ! jq -e --arg c "$cur" 'index($c) != null' <<< "$allowed" > /dev/null; then
    reason="in ${cur}, not one of the columns it may move to ${STATE_NAME} from"
  fi
  if [ -n "$reason" ]; then
    log "$id: not moved ($reason)"
    add "$(jq -nc --arg id "$id" --arg f "$cur" --arg r "$reason" '{id:$id, success:true, moved:false, from:$f, reason:$r}')"
    continue
  fi
  # shellcheck disable=SC2016 # GraphQL variables ($id, $state), not shell expansion.
  resp=$(linear_query 'mutation($id:String!,$state:String!){issueUpdate(id:$id,input:{stateId:$state}){success}}' \
    "$(jq -nc --arg id "$id" --arg s "$STATE_ID" '{id:$id, state:$s}')") || resp='{}'
  ok=$(jq -r '.data.issueUpdate.success // false' <<< "$resp" 2> /dev/null || echo false)
  err=$(jq -r '.errors[0].message // empty' <<< "$resp" 2> /dev/null || true)
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  add "$(jq -nc --arg id "$id" --argjson ok "$ok" --arg f "$cur" --arg err "$err" \
    '{id:$id, success:$ok, moved:$ok, from:$f} + (if $err == "" then {} else {error:$err} end)')"
done <<< "$tickets"

echo "$results"
