#!/usr/bin/env bash
# prod-tickets.sh
#
# Reads ["SIG-1","SIG-2"] on stdin and prints each ticket's Linear column and
# labels, in input order, for the prod Deployment (SIG-2769):
#   [{id, found, state, labels: [names]}]
# A ref Linear does not know ("Entity not found", e.g. a typo in a commit
# message) is kept with found=false so callers can skip it. Any other Linear
# failure exits 1: the deploy window's hotfix bypass, the resume check and the
# Feature flag check all depend on these labels.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

need jq

ids=$(jq -r 'if type == "array" then .[] else error("not an array") end' 2> /dev/null) \
  || die "stdin must be a JSON array of ticket ids"
out='[]'
while IFS= read -r id; do
  [ -n "$id" ] || continue
  rc=0
  # shellcheck disable=SC2016 # GraphQL variable, not shell expansion.
  data=$(linear_gql 'query($id:String!){issue(id:$id){identifier state{name} labels{nodes{name}}}}' \
    "$(jq -nc --arg id "$id" '{id:$id}')") || rc=$?
  case "$rc" in
    0)
      # shellcheck disable=SC2016 # jq bindings, not shell expansion.
      entry=$(jq -c --arg id "$id" '.issue
        | if . == null then {id: $id, found: false, state: null, labels: []}
          else {id: $id, found: true, state: .state.name, labels: [.labels.nodes[].name]} end' <<< "$data") \
        || die "unexpected Linear answer for $id: $data"
      ;;
    3) entry=$(jq -nc --arg id "$id" '{id: $id, found: false, state: null, labels: []}') ;;
    *) die "reading $id from Linear failed" ;;
  esac
  out=$(jq -c --argjson e "$entry" '. + [$e]' <<< "$out")
done <<< "$ids"
echo "$out"
