#!/usr/bin/env bash
# ticket-transitioner.sh <target-state-name>
#
# Reads ["SIG-1","SIG-2"] on stdin. Moves each to the given state on Engineering
# team. Emits [{id, success, error?}, ...] on stdout.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

[ $# -eq 1 ] || die "usage: ticket-transitioner.sh <state-name>"
STATE_NAME="$1"
need jq

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

# Resolve the state ID once (Engineering team).
# shellcheck disable=SC2016 # GraphQL variables ($name), not shell expansion.
STATE_ID=$(linear_query 'query($name:String!){workflowStates(filter:{name:{eq:$name},team:{name:{eq:"Engineering"}}}){nodes{id}}}' \
  "$(jq -nc --arg n "$STATE_NAME" '{name:$n}')" \
  | jq -r '.data.workflowStates.nodes[0].id // empty')
[ -n "$STATE_ID" ] || die "state '$STATE_NAME' not found on team Engineering"

results='[]'
while IFS= read -r id; do
  # shellcheck disable=SC2016 # GraphQL variables ($id, $state), not shell expansion.
  resp=$(linear_query 'mutation($id:String!,$state:String!){issueUpdate(id:$id,input:{stateId:$state}){success}}' \
    "$(jq -nc --arg id "$id" --arg s "$STATE_ID" '{id:$id, state:$s}')")
  ok=$(echo "$resp" | jq -r '.data.issueUpdate.success // false')
  err=$(echo "$resp" | jq -r '.errors[0].message // empty')
  entry=$(jq -nc --arg id "$id" --argjson ok "$ok" --arg err "$err" \
    'if $err == "" then {id:$id, success:$ok} else {id:$id, success:$ok, error:$err} end')
  results=$(echo "$results" | jq -c --argjson e "$entry" '. + [$e]')
done <<< "$tickets"

echo "$results"
